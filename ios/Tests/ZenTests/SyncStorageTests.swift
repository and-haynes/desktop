//  SyncStorageTests.swift
//  The storage client and the account plumbing, driven by MockSyncServer.

import XCTest

@testable import Zen

final class TokenServerTests: XCTestCase {

    private func response(_ json: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], body: Data(json.utf8))
    }

    func testParsesTokenResponse() throws {
        let token = try TokenServerClient.parse(
            response(
                """
                {"id":"hawk-id","key":"hawk-key","uid":12345,
                 "api_endpoint":"https://sync-1.example/1.5/12345",
                 "duration":3600,"hashed_fxa_uid":"abc123","hashalg":"sha256"}
                """))
        XCTAssertEqual(token.hawkID, "hawk-id")
        XCTAssertEqual(token.uid, 12345)
        XCTAssertEqual(
            token.storageEndpoint, URL(string: "https://sync-1.example/1.5/12345"))
        XCTAssertEqual(token.credentials.key, Data("hawk-key".utf8))
        XCTAssertFalse(token.isExpired())
    }

    func testRejectsMalformedTokenResponse() {
        XCTAssertThrowsError(try TokenServerClient.parse(response(#"{"id":"x"}"#)))
    }

    /// The token server path is fixed by the protocol version.
    func testURL() {
        let client = TokenServerClient(
            baseURL: URL(string: "https://token.services.mozilla.com")!,
            transport: MockSyncServer())
        XCTAssertEqual(
            client.url.absoluteString, "https://token.services.mozilla.com/1.0/sync/1.5")
    }

    func testExpiryLeeway() {
        let token = TokenServerToken(
            hawkID: "a", hawkKey: "b", uid: 1,
            storageEndpoint: URL(string: "https://x/1.5/1")!,
            expiresAt: Date().addingTimeInterval(30), hashedFxAUID: "")
        // Thirty seconds left is not enough to start a sync with.
        XCTAssertTrue(token.isExpired(leeway: 60))
        XCTAssertFalse(token.isExpired(leeway: 10))
    }
}

final class FxAOAuthTests: XCTestCase {

    private let client = FxAOAuthClient(transport: MockSyncServer())

    func testAuthorizationURLCarriesPKCEAndKeysJWK() throws {
        let request = try client.authorizationRequest()
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(components.host, "accounts.firefox.com")
        XCTAssertEqual(components.path, "/authorization")
        XCTAssertEqual(items["client_id"], "1b1a3e44c54fbb58")
        XCTAssertEqual(items["redirect_uri"], "urn:ietf:wg:oauth:native:1")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], request.pkce.challenge)
        // Without access_type=offline there is no refresh token, and sync
        // stops working an hour after sign-in.
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(
            items["scope"], "profile https://identity.mozilla.com/apps/oldsync")

        // keys_jwk is the ephemeral public key, base64url'd JSON.
        let jwk = try JSONValue(jsonData: Base64URL.decode(items["keys_jwk"]!)!)
        XCTAssertEqual(jwk["kty"]?.stringValue, "EC")
        XCTAssertEqual(jwk["crv"]?.stringValue, "P-256")
        XCTAssertEqual(
            try ScopedKeyJWE.publicKey(fromJWK: jwk).rawRepresentation,
            request.ephemeralKey.publicKey.rawRepresentation)
    }

    /// The registered redirect is a `urn:`, which URLComponents will not parse
    /// as hierarchical — so the callback parser reads the query itself.
    func testParsesCodeFromNonHierarchicalCallback() throws {
        let url = URL(string: "urn:ietf:wg:oauth:native:1?code=abc123&state=xyz")!
        XCTAssertEqual(
            try FxAOAuthClient.authorizationCode(fromCallback: url, expectedState: "xyz"),
            "abc123")
    }

    func testRejectsMismatchedState() {
        let url = URL(string: "urn:ietf:wg:oauth:native:1?code=abc123&state=attacker")!
        XCTAssertThrowsError(
            try FxAOAuthClient.authorizationCode(fromCallback: url, expectedState: "ours"))
    }

    func testSurfacesServerError() {
        let url = URL(
            string:
                "urn:ietf:wg:oauth:native:1?error=access_denied&error_description=Not%20today&state=xyz"
        )!
        XCTAssertThrowsError(
            try FxAOAuthClient.authorizationCode(fromCallback: url, expectedState: "xyz")
        ) { error in
            XCTAssertEqual(error as? SyncError, .message("Not today"))
        }
    }

    func testMissingCodeIsAnError() {
        let url = URL(string: "urn:ietf:wg:oauth:native:1?state=xyz")!
        XCTAssertThrowsError(
            try FxAOAuthClient.authorizationCode(fromCallback: url, expectedState: "xyz"))
    }

    /// The well-known document overrides the built-in hosts; a missing key
    /// keeps the fallback rather than producing a nil URL.
    func testEndpointDiscovery() throws {
        let json = try JSONValue(
            jsonString: """
                {"auth_server_base_url":"https://api.example/v1",
                 "oauth_server_base_url":"https://oauth.example/v1",
                 "sync_tokenserver_base_url":"https://token.example"}
                """)
        let endpoints = FxAEndpoints(discoveryDocument: json)
        XCTAssertEqual(endpoints.oauthServer, URL(string: "https://oauth.example/v1"))
        XCTAssertEqual(endpoints.tokenServer, URL(string: "https://token.example"))
        XCTAssertEqual(endpoints.profileServer, FxAEndpoints.fallback.profileServer)
    }
}

final class SyncStorageClientTests: XCTestCase {

    private var server: MockSyncServer!
    private var bundle: SyncKeyBundle!

    override func setUp() {
        super.setUp()
        server = MockSyncServer()
        bundle = SyncKeyBundle(keyMaterial: Data(repeating: 0x2b, count: 64))!
    }

    func testInfoCollectionsReflectsWhatIsStored() async throws {
        try server.seedEncrypted(
            collection: "spaces", id: "a", payload: .object(["id": .string("a")]),
            bundle: bundle)
        let info = try await server.client().infoCollections()
        XCTAssertNotNil(info["spaces"])
        XCTAssertNil(info["bookmarks"])
    }

    func testRoundTripThroughTheServer() async throws {
        let client = server.client()
        let record = DecryptedRecord(
            id: "space-1", modified: 0,
            payload: .object([
                "id": .string("space-1"), "kind": .string("space"),
                "data": .object(["name": .string("Work")]),
            ]))
        let result = try await client.post(
            collection: "spaces", records: [record], bundle: bundle, unmodifiedSince: nil)
        XCTAssertEqual(result.success, ["space-1"])

        let fetched = try await client.fetch(collection: "spaces", bundle: bundle)
        XCTAssertEqual(fetched.records.count, 1)
        XCTAssertEqual(fetched.records[0].payload, record.payload)
        XCTAssertGreaterThan(fetched.records[0].modified, 0)

        // The server stored ciphertext, not our JSON.
        XCTAssertFalse(server.records(in: "spaces")[0].payload.contains("Work"))
    }

    func testNewerFiltersToChangesOnly() async throws {
        let client = server.client()
        try server.seedEncrypted(
            collection: "spaces", id: "old", payload: .object(["id": .string("old")]),
            bundle: bundle, modified: 100)
        try server.seedEncrypted(
            collection: "spaces", id: "new", payload: .object(["id": .string("new")]),
            bundle: bundle, modified: 200)

        let all = try await client.fetch(collection: "spaces", bundle: bundle)
        XCTAssertEqual(all.records.count, 2)

        let since = try await client.fetch(collection: "spaces", bundle: bundle, newer: 150)
        XCTAssertEqual(since.records.map(\.id), ["new"])
    }

    func testFetchByIDs() async throws {
        let client = server.client()
        for id in ["a", "b", "c"] {
            try server.seedEncrypted(
                collection: "spaces", id: id, payload: .object(["id": .string(id)]),
                bundle: bundle)
        }
        let some = try await client.fetch(collection: "spaces", bundle: bundle, ids: ["a", "c"])
        XCTAssertEqual(Set(some.records.map(\.id)), ["a", "c"])
    }

    /// Writing with a stale `X-If-Unmodified-Since` must fail loudly: the whole
    /// point is that we notice another device got there first.
    func testUnmodifiedSincePreconditionProduces412() async throws {
        let client = server.client()
        try server.seedEncrypted(
            collection: "spaces", id: "a", payload: .object(["id": .string("a")]),
            bundle: bundle, modified: 500)

        let record = DecryptedRecord(id: "b", modified: 0, payload: .object(["id": .string("b")]))
        do {
            _ = try await client.post(
                collection: "spaces", records: [record], bundle: bundle, unmodifiedSince: 100)
            XCTFail("expected a 412")
        } catch let error as SyncError {
            guard case .server(let status, _) = error else { return XCTFail("wrong error") }
            XCTAssertEqual(status, 412)
        }
    }

    func testUpToDateUnmodifiedSinceSucceeds() async throws {
        let client = server.client()
        try server.seedEncrypted(
            collection: "spaces", id: "a", payload: .object(["id": .string("a")]),
            bundle: bundle, modified: 500)
        let record = DecryptedRecord(id: "b", modified: 0, payload: .object(["id": .string("b")]))
        let result = try await client.post(
            collection: "spaces", records: [record], bundle: bundle, unmodifiedSince: 500)
        XCTAssertEqual(result.success, ["b"])
    }

    /// More than 100 records has to go through the batch protocol and still
    /// land as one set.
    func testLargeUploadIsBatched() async throws {
        let client = server.client()
        let records = (0..<250).map { index in
            DecryptedRecord(
                id: String(format: "id-%03d", index), modified: 0,
                payload: .object(["id": .string(String(format: "id-%03d", index))]))
        }
        let result = try await client.post(
            collection: "spaces", records: records, bundle: bundle, unmodifiedSince: nil)
        XCTAssertNotNil(result.batchID)
        XCTAssertEqual(server.records(in: "spaces").count, 250)
        XCTAssertEqual(result.success.count, 250)
    }

    func testChunkingRespectsBothLimits() {
        let small = (0..<250).map { BasicStorageObject(id: "\($0)", payload: "x") }
        XCTAssertEqual(SyncStorageClient.chunk(small).map(\.count), [100, 100, 50])

        let large = (0..<4).map {
            BasicStorageObject(id: "\($0)", payload: String(repeating: "x", count: 400_000))
        }
        XCTAssertEqual(SyncStorageClient.chunk(large).map(\.count), [2, 2])

        XCTAssertTrue(SyncStorageClient.chunk([]).isEmpty)
    }

    func testDeleteRemovesRecords() async throws {
        let client = server.client()
        try server.seedEncrypted(
            collection: "spaces", id: "a", payload: .object(["id": .string("a")]),
            bundle: bundle)
        try await client.delete(collection: "spaces", ids: ["a"], unmodifiedSince: nil)
        XCTAssertTrue(server.records(in: "spaces").isEmpty)
    }

    /// A 503 with Retry-After parks the client; further requests fail fast
    /// instead of hammering a server that has already said no.
    func testBackoffIsHonoured() async throws {
        let client = server.client()
        server.scriptedResponses = [
            HTTPResponse(status: 503, headers: ["Retry-After": "120"], body: Data())
        ]
        do {
            _ = try await client.infoCollections()
            XCTFail("expected backoff")
        } catch let error as SyncError {
            guard case .backoff(let seconds) = error else { return XCTFail("wrong error") }
            XCTAssertEqual(seconds, 120, accuracy: 1)
        }

        // Still parked — no request should reach the server.
        let before = server.records(in: "spaces").count
        await XCTAssertThrowsErrorAsync(try await client.infoCollections())
        XCTAssertEqual(server.records(in: "spaces").count, before)

        await client.clearBackoff()
        _ = try await client.infoCollections()
    }

    /// A 401 mid-sync means the Hawk credentials expired; renew once and retry,
    /// then give up rather than loop.
    func testRenewsTokenOnceAfter401() async throws {
        let token = server.token()
        let renewals = Counter()
        let client = SyncStorageClient(
            token: token, transport: server,
            renewToken: {
                await renewals.increment()
                return token
            })
        server.scriptedResponses = [
            HTTPResponse(status: 401, headers: [:], body: Data())
        ]
        _ = try await client.infoCollections()
        let count = await renewals.value
        XCTAssertEqual(count, 1)

        server.scriptedResponses = [
            HTTPResponse(status: 401, headers: [:], body: Data()),
            HTTPResponse(status: 401, headers: [:], body: Data()),
        ]
        do {
            _ = try await client.infoCollections()
            XCTFail("expected an authentication failure")
        } catch let error as SyncError {
            XCTAssertEqual(error, .authenticationExpired)
        }
    }

    /// A record we cannot decrypt has to be reported as such, not skipped — a
    /// silent skip looks exactly like "the desktop has no spaces".
    func testUndecryptableRecordThrows() async throws {
        let client = server.client()
        let other = SyncKeyBundle(keyMaterial: Data(repeating: 0x99, count: 64))!
        try server.seedEncrypted(
            collection: "spaces", id: "a", payload: .object(["id": .string("a")]),
            bundle: other)
        do {
            _ = try await client.fetch(collection: "spaces", bundle: bundle)
            XCTFail("expected a decryption failure")
        } catch let error as SyncError {
            XCTAssertEqual(error, .decryptionFailed(collection: "spaces", id: "a"))
        }
    }

    func testTimestampFormatIsTwoDecimalPlaces() {
        XCTAssertEqual(SyncStorageClient.format(1_700_000_000), "1700000000.00")
        XCTAssertEqual(SyncStorageClient.format(1.005), "1.00")
        XCTAssertEqual(SyncStorageClient.format(1.999), "2.00")
    }

    func testURLBuilding() async {
        let client = server.client()
        let url = await client.url(
            path: "storage/spaces", query: [URLQueryItem(name: "full", value: "1")])
        XCTAssertEqual(url.absoluteString, "https://sync.example/1.5/12345/storage/spaces?full=1")
    }

    /// Every request must be Hawk-signed, or the real server 401s all of them.
    func testEveryRequestIsHawkSigned() async throws {
        let client = server.client()
        _ = try await client.infoCollections()
        _ = try await client.post(
            collection: "spaces",
            records: [DecryptedRecord(id: "a", modified: 0, payload: .object([:]))],
            bundle: bundle, unmodifiedSince: nil)
        XCTAssertFalse(server.requests.isEmpty)
        for request in server.requests {
            let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
            XCTAssertTrue(header.hasPrefix("Hawk id=\"mock-id\""), header)
            XCTAssertTrue(header.contains("mac=\""))
            if request.httpBody != nil {
                XCTAssertTrue(header.contains("hash=\""), "a body must be covered by the MAC")
            }
        }
    }
}

final class MetaGlobalAndKeysTests: XCTestCase {

    func testMetaGlobalRoundTrip() throws {
        let meta = MetaGlobal(
            syncID: "abcdefghijkl", storageVersion: 5,
            engines: [
                "spaces": .init(version: 3, syncID: "sss"),
                "bookmarks": .init(version: 2, syncID: "bbb"),
            ],
            declined: ["addons"])
        XCTAssertEqual(MetaGlobal(json: meta.json), meta)
    }

    /// Zen desktop registers its engine as `spaces` at version 3
    /// (`ZenSpacesSyncEngine.version`). A mismatch makes the desktop wipe the
    /// collection, so this constant is load-bearing.
    func testSpacesEngineVersionMatchesDesktop() {
        XCTAssertEqual(SyncConfig.engineVersions["spaces"], 3)
        XCTAssertEqual(SyncConfig.storageVersion, 5)
    }

    func testCryptoKeysRoundTrip() throws {
        let keys = CollectionKeys(
            defaultBundle: SyncKeyBundle(keyMaterial: Data(repeating: 1, count: 64))!,
            collections: [
                "spaces": SyncKeyBundle(keyMaterial: Data(repeating: 2, count: 64))!
            ])
        let decoded = try XCTUnwrap(CollectionKeys(json: keys.json))
        XCTAssertEqual(decoded.bundle(for: "spaces"), keys.bundle(for: "spaces"))
        XCTAssertEqual(decoded.bundle(for: "bookmarks"), keys.bundle(for: "bookmarks"))
        XCTAssertNotEqual(decoded.bundle(for: "spaces"), decoded.bundle(for: "bookmarks"))
    }

    func testCryptoKeysAreFetchedWithTheAccountKeyNotACollectionKey() async throws {
        let server = MockSyncServer()
        let syncKey = SyncKeyBundle(keyMaterial: Data(repeating: 0x33, count: 64))!
        let keys = CollectionKeys.generate()
        try server.seedEncrypted(
            collection: "crypto", id: "keys", payload: keys.json, bundle: syncKey)

        let fetched = try await server.client().cryptoKeys(syncKey: syncKey)
        XCTAssertEqual(fetched?.bundle(for: "spaces"), keys.bundle(for: "spaces"))
    }

    func testGUIDShape() {
        for _ in 0..<64 {
            let guid = SyncGUID.generate()
            XCTAssertEqual(guid.count, 12)
            XCTAssertTrue(SyncGUID.isValid(guid))
        }
        XCTAssertFalse(SyncGUID.isValid("short"))
        XCTAssertFalse(SyncGUID.isValid("has a space!"))
    }

    /// The same local object must map to the same sync guid every launch, or
    /// every sync uploads a duplicate.
    func testDerivedGUIDIsStable() {
        let seed = UUID().uuidString
        XCTAssertEqual(SyncGUID.derived(from: seed), SyncGUID.derived(from: seed))
        XCTAssertTrue(SyncGUID.isValid(SyncGUID.derived(from: seed)))
        XCTAssertNotEqual(SyncGUID.derived(from: seed), SyncGUID.derived(from: "other"))
    }
}

// MARK: - Helpers

/// An actor-isolated counter, so a `@Sendable` closure can record calls.
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // expected
    }
}
