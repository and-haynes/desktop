//  OnePasswordConnectTests.swift
//  `OnePasswordConnectClient` and `OnePasswordVaultProvider`, against a fake
//  Connect server (#008AD).
//
//  **Everything here is mocked, on purpose.** Neither vault backend this
//  feature talks to — 1Password Connect or Vaultwarden/Bitwarden — is
//  reachable from a build machine: both are homelab services behind
//  `vault.lan`/`connect.lan`, on a network no CI runner or contributor's Mac
//  is assumed to be on. A test suite that skipped when the network was
//  unavailable would mean "green" stopped meaning anything on the machine
//  that actually runs these tests, so this file (and its Bitwarden sibling,
//  under the same constraint) never makes a real request. Every HTTP call
//  here is intercepted by `MockConnectURLProtocol`, registered on a private
//  `URLSessionConfiguration` that only this file's client ever uses, and
//  answered from the fixtures under `Tests/Fixtures/onepassword-connect/` —
//  JSON shaped like real 1Password Connect API responses (see
//  `OnePasswordConnectClient.swift`'s header for the shapes and why they are
//  what they are).
//
//  The fixtures come out of the test bundle: `project.yml` adds
//  `Tests/Fixtures` to the `ZenTests` target as a *folder reference*, so the
//  directory structure survives into the bundle and two subjects (`forms/`,
//  `onepassword-connect/`) cannot collide on a file name. `LoginFormFillTests`
//  loads its HTML the same way.

import XCTest

@testable import Zen

// MARK: - Mock transport

/// Intercepts every request on the `URLSessionConfiguration` it is
/// registered on and answers from a closure instead of the network.
///
/// The handler is a `static var` rather than an instance property because
/// `URLSession` instantiates `URLProtocol` subclasses itself — a test's only
/// hand-off point is a slot the test fills in before firing a request. Tests
/// in an `XCTestCase` run serially by default, so there is no race on it, and
/// each test overwrites it before use rather than relying on any previous
/// value.
final class MockConnectURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Records every request a handler is given, for the create/update
/// request-body-shape assertions. A plain array would race across the
/// background queue `URLSession` delivers `startLoading()` on; the lock
/// mirrors `MockSyncServer`'s.
final class RequestRecorder: @unchecked Sendable {

    /// A request *and* the body it actually carried.
    ///
    /// The body has to be resolved at record time, and it cannot be read from
    /// `httpBody`: by the time `URLSession` hands a request to a `URLProtocol`
    /// it has moved any body onto `httpBodyStream`, leaving `httpBody` nil. A
    /// test that reads `httpBody` therefore unwraps nil on every request that
    /// had one — which looks like "the client sent no body" and is really "the
    /// test looked in the wrong place".
    struct Recorded {
        var request: URLRequest
        var body: Data?
    }

    private let lock = NSLock()
    private var stored: [Recorded] = []

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(Recorded(request: request, body: Self.body(of: request)))
    }

    var recorded: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var requests: [URLRequest] { recorded.map(\.request) }

    /// The body of the first request made with `method`.
    func body(forMethod method: String) -> Data? {
        recorded.first { $0.request.httpMethod == method }?.body
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

// MARK: - Fixtures

enum ConnectFixtures {
    /// Out of the test bundle's `Fixtures/onepassword-connect` folder.
    static func data(_ name: String) -> Data {
        let bundle = Bundle(for: OnePasswordConnectTests.self)
        guard
            let url = bundle.url(
                forResource: (name as NSString).deletingPathExtension,
                withExtension: (name as NSString).pathExtension,
                subdirectory: "Fixtures/onepassword-connect"),
            let data = try? Data(contentsOf: url)
        else {
            XCTFail("missing fixture \(name) in the test bundle")
            return Data()
        }
        return data
    }

    static var vaults: Data { data("vaults.json") }
    static var items: Data { data("items.json") }
    static var itemDetail: Data { data("item-detail.json") }
}

// MARK: - Test case

final class OnePasswordConnectTests: XCTestCase {

    private let baseURL = URL(string: "https://connect.example:8080")!

    override func tearDown() {
        MockConnectURLProtocol.handler = nil
        super.tearDown()
    }

    /// A session configuration wired to the mock protocol and nothing else —
    /// never `.default`/`.shared`, which other tests in the process also use.
    private func mockConfiguration(
        _ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)
    ) -> URLSessionConfiguration {
        MockConnectURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockConnectURLProtocol.self]
        return configuration
    }

    private func client(
        allowsSelfSignedTLS: Bool = false,
        handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)
    ) -> OnePasswordConnectClient {
        OnePasswordConnectClient(
            baseURL: baseURL, token: "connect-test-token",
            allowsSelfSignedTLS: allowsSelfSignedTLS,
            sessionConfiguration: mockConfiguration(handler))
    }

    private func provider(
        handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)
    ) -> OnePasswordVaultProvider {
        OnePasswordVaultProvider(
            baseURL: baseURL, token: "connect-test-token",
            urlSessionConfiguration: mockConfiguration(handler))
    }

    /// Routes the GETs `allLogins()`/`verifyConnection()`/`reveal(_:)` make
    /// against the single-vault fixture set. Deliberately `GET`-only: a
    /// create/update test's `POST`/`PUT` shares a path with one of these
    /// (`/v1/vaults/vault1/items` is both "list summaries" and "create"),
    /// and matching on path alone would silently hand a create request the
    /// list-summaries fixture instead of falling through to the test's own
    /// route for it.
    private func standardRoute(for request: URLRequest) -> (Int, [String: String], Data)? {
        guard let path = request.url?.path, request.httpMethod == "GET" else { return nil }
        switch path {
        case "/v1/vaults":
            return (200, [:], ConnectFixtures.vaults)
        case "/v1/vaults/vault1/items":
            return (200, [:], ConnectFixtures.items)
        case "/v1/vaults/vault1/items/item1":
            return (200, [:], ConnectFixtures.itemDetail)
        default:
            return nil
        }
    }

    // MARK: Vault listing

    func testVerifyConnectionListsVaults() async throws {
        let subject = client { request in
            guard let route = self.standardRoute(for: request) else {
                XCTFail("unexpected request \(request.url?.absoluteString ?? "?")")
                return (500, [:], Data())
            }
            return route
        }
        let vaults = try await subject.listVaults()
        XCTAssertEqual(vaults.count, 1)
        XCTAssertEqual(vaults[0].id, "vault1")
        XCTAssertEqual(vaults[0].name, "Personal")
        XCTAssertEqual(vaults[0].items, 2)
    }

    func testProviderVerifyConnectionReturnsVaultSummaries() async throws {
        let subject = provider { request in
            self.standardRoute(for: request) ?? (500, [:], Data())
        }
        let summaries = try await subject.verifyConnection()
        XCTAssertEqual(summaries, [VaultSummary(id: "vault1", name: "Personal", itemCount: 2)])
    }

    // MARK: Item-summary -> VaultLogin mapping

    /// Summaries carry no fields, so `allLogins()` must hand back secrets as
    /// `nil` — not merely unset, but the honest reflection of what Connect's
    /// list endpoint actually returned. This is the assertion that would fail
    /// first if that two-phase split were ever accidentally collapsed.
    func testAllLoginsMapsSummariesWithoutSecretsAndFiltersNonLoginCategories() async throws {
        let subject = provider { request in
            self.standardRoute(for: request) ?? (500, [:], Data())
        }
        let logins = try await subject.allLogins()

        // item2 is a SECURE_NOTE in the fixture and must not appear.
        XCTAssertEqual(logins.count, 1)
        let login = try XCTUnwrap(logins.first)

        XCTAssertEqual(login.id, VaultItemID("vault1/item1"))
        XCTAssertEqual(login.title, "Example Site")
        XCTAssertNil(login.username)
        XCTAssertNil(login.password)
        XCTAssertNil(login.totp)
        XCTAssertFalse(login.hasSecrets)
        XCTAssertEqual(login.vaultName, "Personal")
    }

    // MARK: URL mapping

    func testURLsMapToDomainMatchVaultURIs() async throws {
        let subject = provider { request in
            self.standardRoute(for: request) ?? (500, [:], Data())
        }
        let logins = try await subject.allLogins()
        let login = try XCTUnwrap(logins.first)

        XCTAssertEqual(login.uris.count, 1)
        let uri = try XCTUnwrap(login.uris.first)
        XCTAssertEqual(uri.uri, "https://example.com/login")
        // 1Password has no per-URI match-type field to read — `.domain` is
        // the deliberate default, not a leftover of "primary": true. See the
        // comment on `OnePasswordVaultProvider.uris(from:)`.
        XCTAssertEqual(uri.match, .domain)
    }

    // MARK: Full-item parsing

    /// The per-item GET is the only place Connect returns `fields`; this is
    /// where username, password and the OTP URI actually get pulled out by
    /// `purpose`/`type`.
    func testRevealParsesFieldsByPurposeAndType() async throws {
        let subject = provider { request in
            self.standardRoute(for: request) ?? (500, [:], Data())
        }
        let revealed = try await subject.reveal(VaultItemID("vault1/item1"))

        XCTAssertEqual(revealed.id, VaultItemID("vault1/item1"))
        XCTAssertEqual(revealed.username, "alice@example.com")
        XCTAssertEqual(revealed.password, "hunter2-trombone-CORRECT")
        XCTAssertEqual(
            revealed.totp,
            "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP"
                + "&issuer=Example&algorithm=SHA1&digits=6&period=30")
        XCTAssertTrue(revealed.hasSecrets)
        // The detail endpoint's `vault` object is id-only — see the comment
        // on `OnePasswordVaultProvider.login(from: OnePasswordConnect.Item)`.
        XCTAssertNil(revealed.vaultName)
    }

    func testRevealRejectsAnIDWithNoPackedVaultID() async throws {
        let subject = provider { request in
            self.standardRoute(for: request) ?? (500, [:], Data())
        }
        do {
            _ = try await subject.reveal(VaultItemID("not-a-composite-id"))
            XCTFail("expected a VaultError.notFound")
        } catch VaultError.notFound {
            // expected
        }
    }

    // MARK: Error mapping

    func testUnauthorizedSurfacesAsServerError() async throws {
        let subject = client { _ in
            let body = #"{"status":401,"message":"Authentication required."}"#
            return (401, [:], Data(body.utf8))
        }
        do {
            _ = try await subject.listVaults()
            XCTFail("expected a VaultError.server")
        } catch VaultError.server(let status, let message) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "Authentication required.")
        }
    }

    func testNotFoundSurfacesAsServerError() async throws {
        let subject = client { request in
            if request.url?.path == "/v1/vaults" {
                return (200, [:], ConnectFixtures.vaults)
            }
            let body = #"{"status":404,"message":"Item not found."}"#
            return (404, [:], Data(body.utf8))
        }
        do {
            _ = try await subject.item(vaultID: "vault1", itemID: "does-not-exist")
            XCTFail("expected a VaultError.server")
        } catch VaultError.server(let status, let message) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(message, "Item not found.")
        }
    }

    /// Never logged, never in an error message — this test is the one place
    /// that would notice a regression where the token leaked into a thrown
    /// `VaultError`.
    func testServerErrorMessageNeverContainsTheToken() async throws {
        let subject = client { _ in
            (401, [:], Data(#"{"status":401,"message":"nope"}"#.utf8))
        }
        do {
            _ = try await subject.listVaults()
            XCTFail("expected a VaultError.server")
        } catch VaultError.server(_, let message) {
            XCTAssertFalse(message.contains("connect-test-token"))
        }
    }

    func testMalformedBodySurfacesAsDecodingError() async throws {
        let subject = client { _ in
            (200, [:], Data("{ this is not json".utf8))
        }
        do {
            _ = try await subject.listVaults()
            XCTFail("expected a VaultError.decoding")
        } catch VaultError.decoding {
            // expected
        }
    }

    // MARK: Create / update request-body shape

    func testCreateLoginSendsALoginItemWithNoIDKey() async throws {
        let recorder = RequestRecorder()
        let subject = provider { request in
            recorder.record(request)
            if let route = self.standardRoute(for: request) { return route }
            // The one route `standardRoute` does not know: the create POST.
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/vaults/vault1/items")
            return (200, [:], ConnectFixtures.itemDetail)
        }
        let draft = VaultLoginDraft(
            title: "New Site", username: "bob", password: "s3cret",
            uri: "https://new.example.com", totp: "JBSWY3DPEHPK3PXP")
        _ = try await subject.createLogin(draft)

        let body = try XCTUnwrap(recorder.body(forMethod: "POST"))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])

        // No id key at all for a create — not `"id": null` — see the
        // `ItemWrite.encode(to:)` comment.
        XCTAssertNil(json["id"])
        XCTAssertEqual(json["category"] as? String, "LOGIN")
        XCTAssertEqual(json["title"] as? String, "New Site")
        XCTAssertEqual((json["vault"] as? [String: Any])?["id"] as? String, "vault1")

        let fields = try XCTUnwrap(json["fields"] as? [[String: Any]])
        let username = fields.first { $0["purpose"] as? String == "USERNAME" }
        let password = fields.first { $0["purpose"] as? String == "PASSWORD" }
        let totp = fields.first { $0["type"] as? String == "OTP" }
        XCTAssertEqual(username?["value"] as? String, "bob")
        XCTAssertEqual(password?["value"] as? String, "s3cret")
        XCTAssertEqual(totp?["value"] as? String, "JBSWY3DPEHPK3PXP")

        let urls = try XCTUnwrap(json["urls"] as? [[String: Any]])
        XCTAssertEqual(urls.first?["href"] as? String, "https://new.example.com")
    }

    func testUpdateLoginSendsTheItemIDInTheBody() async throws {
        let recorder = RequestRecorder()
        let subject = provider { request in
            recorder.record(request)
            if let route = self.standardRoute(for: request) { return route }
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/v1/vaults/vault1/items/item1")
            return (200, [:], ConnectFixtures.itemDetail)
        }
        let draft = VaultLoginDraft(
            title: "Example Site", username: "alice@example.com",
            password: "a-new-password", uri: "https://example.com/login")
        _ = try await subject.updateLogin(VaultItemID("vault1/item1"), with: draft)

        let body = try XCTUnwrap(recorder.body(forMethod: "PUT"))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["id"] as? String, "item1")
        XCTAssertEqual((json["vault"] as? [String: Any])?["id"] as? String, "vault1")
        XCTAssertEqual(json["category"] as? String, "LOGIN")
    }
}
