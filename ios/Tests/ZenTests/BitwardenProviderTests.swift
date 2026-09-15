//  BitwardenProviderTests.swift
//  `BitwardenVaultProvider` driven end to end — sign in, decrypt a vault,
//  write a login back — without a Vaultwarden anywhere (#008AD).
//
//  **Every network exchange in this file is a mock.** No Vaultwarden is
//  reachable from the machine these tests run on, and that is the right state
//  of affairs: a test that *can* reach a real vault is a test that one day
//  will, on someone's laptop, against their actual passwords. A
//  `URLProtocol` subclass registered on a private `URLSessionConfiguration`
//  intercepts every request before it reaches a socket, so these tests pass
//  identically on a plane.
//
//  The stub sits at `URLProtocol` rather than behind a transport protocol of
//  our own because the code under test builds its own `URLSession`, and this
//  is the only seam that proves the *real* one is wired up correctly — headers,
//  form encoding, query items and all. A hand-rolled transport would test the
//  code path tests use and leave the shipping one unexercised.
//
//  The `/api/sync` fixture was generated outside Swift (python + `openssl enc`
//  + a separately computed HMAC) against the same user key
//  `BitwardenCryptoTests` pins, so the ciphers here are opened by the same code
//  path a real vault's would be, not by a round trip through our own writer.
//  Its plaintexts are listed beside it so the assertions are readable.
//
//  One deliberate cost: the fixture account is at Vaultwarden's live 600 000
//  PBKDF2 iterations, so each unlock really does run 600 000 rounds. That is a
//  fraction of a second per test, and it is the price of using recorded
//  material from the real server rather than a weakened account that would not
//  prove interoperability.

import Foundation
import XCTest

@testable import Zen

// MARK: - The mock server

/// Records what was asked for and answers from a routing closure.
///
/// `@unchecked Sendable`: `URLProtocol` calls in on a `URLSession` worker
/// thread while the test body reads `requests` from its own, so every access
/// goes through the lock.
final class BitwardenMockServer: @unchecked Sendable {

    struct Request {
        var method: String
        var path: String
        var query: String?
        var body: Data

        var bodyText: String { String(data: body, encoding: .utf8) ?? "" }
    }

    struct Reply {
        var status: Int
        var body: Data

        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(text.utf8))
        }
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private let route: @Sendable (Request) -> Reply

    init(route: @escaping @Sendable (Request) -> Reply) {
        self.route = route
    }

    func handle(_ request: Request) -> Reply {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        return route(request)
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requests(matching fragment: String) -> [Request] {
        requests.filter { $0.path.contains(fragment) }
    }
}

/// Intercepts every request made through a configuration it is registered on.
final class BitwardenMockURLProtocol: URLProtocol {

    /// The server the current test is running against.
    ///
    /// A static because `URLSession` constructs `URLProtocol` instances itself
    /// and there is no way to hand one a dependency. Safe here because XCTest
    /// runs the tests of one class serially in one process: `makeProvider` sets
    /// it, `tearDown` clears it.
    static var server: BitwardenMockServer?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.server else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let reply = server.handle(
            BitwardenMockServer.Request(
                method: request.httpMethod ?? "GET",
                path: url.path,
                query: components?.query,
                body: Self.body(of: request)))

        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Read a request's body.
    ///
    /// `URLRequest.httpBody` is **nil** by the time a `URLProtocol` sees it:
    /// `URLSession` moves the body to `httpBodyStream` on its way down. Asking
    /// for `httpBody` and asserting on the result is the classic way to write a
    /// mock that silently believes every request was empty, so drain the stream
    /// instead.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}

// MARK: - Recorded bodies

enum BitwardenServerFixtures {

    /// Live, unauthenticated response from the homelab's Vaultwarden at
    /// https://vault.lan — copied verbatim, including the nulls.
    static let preloginJSON = #"""
        {"kdf":0,"kdfIterations":600000,"kdfMemory":null,"kdfParallelism":null}
        """#

    /// A token response in the casing a real one arrives in: OAuth
    /// `snake_case` beside Bitwarden's `PascalCase`, in one object.
    static let tokenJSON = #"""
        {
          "access_token": "fixture-access-token",
          "expires_in": 3600,
          "token_type": "Bearer",
          "refresh_token": "fixture-refresh-token",
          "scope": "api offline_access",
          "Key": "2.oKGio6SlpqeoqaqrrK2urw==|Cfjw2Zd8yCcwooLZlL8Vbt5EMJDhqsu4bKxcnWqehgJMMiAlau+EoJkPMxI7cLHXpa6u1Vj38j5cWFjrkQPsO9eYFPYlgPntKRffM8gU1X8=|aGjOYrhPYeQETqJ2QeZdHKW2DGy0bG0HZtJcZyiz4i4=",
          "PrivateKey": null,
          "Kdf": 0,
          "KdfIterations": 600000,
          "KdfMemory": null,
          "KdfParallelism": null
        }
        """#

    static let invalidGrantJSON = #"""
        {"error":"invalid_grant",
         "error_description":"Username or password is incorrect. Try again."}
        """#

    /// A vault holding, in order:
    ///
    ///   1. **GitHub** (type 1) in folder "Personal" — `andy@example.com` /
    ///      `correct-horse-battery-staple`, TOTP seed `JBSWY3DPEHPK3PXP`, two
    ///      URIs: `https://github.com/login` with a **null** match and
    ///      `github.com` with match 1 (host).
    ///   2. **Homelab router** (type 1), no folder — `admin` /
    ///      `hunter2-but-longer`, no TOTP, one URI `https://10.0.0.1/` with
    ///      match 3 (exact).
    ///   3. **Shared billing** (type 1) owned by an organisation and encrypted
    ///      with a key we never unwrap — unreadable by construction.
    ///   4. **Deleted login** (type 1) with a `deletedDate` — in the trash.
    ///   5. a type 2 secure note and 6. a type 4 identity — neither is a login.
    ///
    /// Every EncString was produced by `openssl enc -aes-256-cbc` under the
    /// user key from `BitwardenFixtures.userKeyBase64`, with the HMAC computed
    /// separately; the IVs are counters so a diff of this fixture is readable.
    static let syncJSON = #"""
        {
          "object": "sync",
          "profile": {
            "object": "profile",
            "id": "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0",
            "email": "test@bitwarden.com",
            "name": "Andy",
            "key": "2.oKGio6SlpqeoqaqrrK2urw==|Cfjw2Zd8yCcwooLZlL8Vbt5EMJDhqsu4bKxcnWqehgJMMiAlau+EoJkPMxI7cLHXpa6u1Vj38j5cWFjrkQPsO9eYFPYlgPntKRffM8gU1X8=|aGjOYrhPYeQETqJ2QeZdHKW2DGy0bG0HZtJcZyiz4i4=",
            "organizations": []
          },
          "folders": [
            {
              "object": "folder",
              "id": "f0000000-0000-4000-8000-000000000001",
              "name": "2.AQEBAQEBAQEBAQEBAQEBAQ==|mzajvDWKEoxmkHqvy2hHcw==|pGGalPmfvWZ6YkApMANh4L3ZZCZlW+v/i6dtwmT3VU4=",
              "revisionDate": "2026-09-01T00:00:00.0000000Z"
            }
          ],
          "collections": [],
          "policies": [],
          "sends": [],
          "domains": null,
          "ciphers": [
            {
              "object": "cipherDetails",
              "id": "11111111-2222-3333-4444-555555555555",
              "organizationId": null,
              "folderId": "f0000000-0000-4000-8000-000000000001",
              "type": 1,
              "name": "2.AgICAgICAgICAgICAgICAg==|QOGJOwdw8kxinmWavAEdIA==|yvzurEL+q4r+jKFMx2OUfgyd1P+egPOPX2khoISkf18=",
              "notes": null,
              "favorite": false,
              "reprompt": 0,
              "login": {
                "username": "2.AwMDAwMDAwMDAwMDAwMDAw==|5CH2R1AFHcCUZOwXTN1cPmjQF6PBespQ7Py0TOkuxs4=|j+OyO0Uj+llPpRcZG9dEndLt+siLaynDFOvX6CA1PDU=",
                "password": "2.BAQEBAQEBAQEBAQEBAQEBA==|tAE9zdsbCjsCHBc+T5mK7tmJcmG/nacBzvbk43Dcz6Y=|kMcrBYvf35YfhdfRo66ab9ibBWeQ9marugn+Y9BxBVU=",
                "totp": "2.BQUFBQUFBQUFBQUFBQUFBQ==|9amqSExxkHPpSiH/Cw7pSjkPutUFs8B8pb4VrvA8yWI=|ZNQHssno326c+tKx4RmtfoRLjPFYW2yDMB8LuGtGFd0=",
                "uris": [
                  {
                    "uri": "2.BgYGBgYGBgYGBgYGBgYGBg==|/VnOnAFC8KwCzPdPpcmNObWayEucZQlEit5lv1fFjNM=|+JoFB83M0kelqWYMg5J5swOdbgU5nKx+bThsGaG4SHA=",
                    "match": null
                  },
                  {
                    "uri": "2.BwcHBwcHBwcHBwcHBwcHBw==|Mk9QqAfR2bw3z6atqx8NcA==|PCTrdSd8pADmMywScMHW6FHNNLjQ8XvjwZZFfmuWdGU=",
                    "match": 1
                  }
                ]
              },
              "revisionDate": "2026-09-14T12:00:00.0000000Z",
              "deletedDate": null
            },
            {
              "object": "cipherDetails",
              "id": "22222222-3333-4444-5555-666666666666",
              "organizationId": null,
              "folderId": null,
              "type": 1,
              "name": "2.CAgICAgICAgICAgICAgICA==|YqhypfPndXByTXI/vZE3pQ==|39oHa+Jd+AnpWKLerkomuskdaA6yqsuB4ie1DLFOWwU=",
              "notes": null,
              "favorite": false,
              "reprompt": 0,
              "login": {
                "username": "2.CQkJCQkJCQkJCQkJCQkJCQ==|ZFurY9+S6KIRxTrDo5ANVw==|/cB1KjeCRXUpUVDVz6tnSNXDIQcYZsYX9Oy58/RpzpU=",
                "password": "2.CgoKCgoKCgoKCgoKCgoKCg==|X6ghXy75Yw1x9I2VRkhMFqEujZ0zzkdwjKyJJGoTuSs=|spRqAmmFs9bUCZSdBOQ3VhfqddTAMOQ4eQg09uWgZz4=",
                "totp": null,
                "uris": [
                  {
                    "uri": "2.CwsLCwsLCwsLCwsLCwsLCw==|Vq3G3ZMAmVfayJnzCIYvH9iCM8IhjOkyi5ru/bdMoaE=|ipOEVtc5qLsGrl1crFvfEI+R8rqpKzFZ9xZ/1B0opyk=",
                    "match": 3
                  }
                ]
              },
              "revisionDate": "2026-09-14T12:00:00.0000000Z",
              "deletedDate": null
            },
            {
              "object": "cipherDetails",
              "id": "33333333-4444-5555-6666-777777777777",
              "organizationId": "0aaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
              "folderId": null,
              "type": 1,
              "name": "2.DAwMDAwMDAwMDAwMDAwMDA==|AdpvHZTYURWgnZOmb0aNCg==|tPhDZqbUem0Lup3HJ+4h19JpjBSbm9OfQvr35qkhV+s=",
              "notes": null,
              "favorite": false,
              "reprompt": 0,
              "login": {
                "username": "2.DQ0NDQ0NDQ0NDQ0NDQ0NDQ==|DNHHcPhSjS7SbrTOquFB88pBFeZu2g+ZEKOCMMI0wDo=|u4xai4SQ8VjhBqZUncSu8kFjBfUwB5fUVZ6NuwCaYQM=",
                "password": "2.Dg4ODg4ODg4ODg4ODg4ODg==|0f1fz4Gvh9P/Io/0013BIA==|u0H7NZ9KLQ3CqnkPSP8txE95STg80WWMp8Nsrz6wOew=",
                "totp": null,
                "uris": [
                  {
                    "uri": "2.Dw8PDw8PDw8PDw8PDw8PDw==|lDF0x6VJMD/KaQNNfpwYYw90f5gysvIIlHn8NTsabEI=|z1yFSF0a5yTOo6eJ8N6DU8ziIE2NsjmuPYbhAGMwD24=",
                    "match": 0
                  }
                ]
              },
              "revisionDate": "2026-09-14T12:00:00.0000000Z",
              "deletedDate": null
            },
            {
              "object": "cipherDetails",
              "id": "44444444-5555-6666-7777-888888888888",
              "organizationId": null,
              "folderId": null,
              "type": 1,
              "name": "2.EBAQEBAQEBAQEBAQEBAQEA==|Q5UQYFHJfe0UXVLxThoGcA==|XOJh+NQ1yHjGQUZNL8cM6+w6oNSLqICxwEdIQhUf0Q0=",
              "notes": null,
              "favorite": false,
              "reprompt": 0,
              "login": {
                "username": "2.EREREREREREREREREREREQ==|ANoDi4nfyMiIeePhQmIckQ==|dO3lvF2hPdxrAicKi2+pLuqdR0ZqybobAHHkMS+YJzg=",
                "password": "2.EhISEhISEhISEhISEhISEg==|B150xogyu3O/Wg2ISRESCA==|knVIybsuQumjlXm7YwQ6v6OB1AaBPIdc8UEzH4/wnrI=",
                "totp": null,
                "uris": [
                  {
                    "uri": "2.ExMTExMTExMTExMTExMTEw==|wJKPsc8PhpM379lEDfZb02rsTy91QnxKi4KfIQPAHLg=|KZuKoE/AS3+UHVuAfZDY0OGptO4eIWg+1QkiM4yEi14=",
                    "match": 0
                  }
                ]
              },
              "revisionDate": "2026-09-14T12:00:00.0000000Z",
              "deletedDate": "2026-09-02T00:00:00.0000000Z"
            },
            {
              "object": "cipherDetails",
              "id": "55555555-6666-7777-8888-999999999999",
              "organizationId": null,
              "folderId": null,
              "type": 2,
              "name": "2.FBQUFBQUFBQUFBQUFBQUFA==|hdCniuXWuWX19FvvZQYyEw==|yYc6aI8ADXGuicMADZ0eJPdwSGgZANcVMvqBYRrugo4=",
              "notes": "2.FRUVFRUVFRUVFRUVFRUVFQ==|VASnatBopavOELi7tz3BoA==|cme4FDanr/bECfnTd0OE7faIkNNaR5xWOLEA6usRwwE=",
              "favorite": false,
              "reprompt": 0,
              "secureNote": { "type": 0 },
              "revisionDate": "2026-09-03T00:00:00.0000000Z",
              "deletedDate": null
            },
            {
              "object": "cipherDetails",
              "id": "66666666-7777-8888-9999-aaaaaaaaaaaa",
              "organizationId": null,
              "folderId": null,
              "type": 4,
              "name": "2.FhYWFhYWFhYWFhYWFhYWFg==|S5RaAFdgS+yKgAE4hO47Vw==|SUHITNIymXvXyvfIPg7v3ZoULndx2j/dEJuMJX2NB/M=",
              "notes": null,
              "favorite": false,
              "reprompt": 0,
              "identity": {
                "firstName": "2.FxcXFxcXFxcXFxcXFxcXFw==|4g91JtmHKgEbAxpUbrWExQ==|Il3lCy5IVuSR618bZFu73LYelVW8bFLC4FaQkYwcx5o="
              },
              "revisionDate": "2026-09-04T00:00:00.0000000Z",
              "deletedDate": null
            }
          ]
        }
        """#

    /// The everyday vault: prelogin, token, sync, and cipher writes echoed
    /// back the way the server echoes them.
    ///
    /// - Parameter servesAtRoot: when true the server 404s anything under
    ///   `/identity` or `/api` and answers at the root instead — a reverse
    ///   proxy that strips the prefix, which the client has to survive.
    static func vault(
        prelogin: String = preloginJSON,
        token: String = tokenJSON,
        tokenStatus: Int = 200,
        sync: String = syncJSON,
        servesAtRoot: Bool = false
    ) -> BitwardenMockServer {
        BitwardenMockServer { request in
            let path = request.path
            if servesAtRoot, path.hasPrefix("/identity/") || path.hasPrefix("/api/") {
                return .json(#"{"message":"Not Found"}"#, status: 404)
            }
            if path.hasSuffix("/accounts/prelogin") {
                return .json(prelogin)
            }
            if path.hasSuffix("/connect/token") {
                return .json(token, status: tokenStatus)
            }
            if path.hasSuffix("/sync") {
                return .json(sync)
            }
            if path.contains("/ciphers") {
                let id =
                    request.method == "PUT"
                    ? String(path.split(separator: "/").last ?? "")
                    : "99999999-8888-7777-6666-555555555555"
                return Reply(status: 200, body: echo(request.body, id: id))
            }
            return .json(#"{"message":"No stub route for \#(path)"}"#, status: 404)
        }
    }

    private typealias Reply = BitwardenMockServer.Reply

    /// Echo a written cipher back with a server-assigned id, which is what
    /// Bitwarden does. The fields come straight back as sent, still encrypted —
    /// so a test that reads the result is also testing our own writer.
    private static func echo(_ body: Data, id: String) -> Data {
        var echoed: [String: Any] = [
            "object": "cipherDetails",
            "id": id,
            "type": 1,
            "revisionDate": "2026-09-15T10:00:00.0000000Z",
        ]
        if let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            echoed["name"] = parsed["name"]
            echoed["login"] = parsed["login"]
            echoed["folderId"] = parsed["folderId"]
        }
        return (try? JSONSerialization.data(withJSONObject: echoed)) ?? Data("{}".utf8)
    }
}

// MARK: - Tests

final class BitwardenProviderTests: XCTestCase {

    override func tearDown() {
        BitwardenMockURLProtocol.server = nil
        super.tearDown()
    }

    private func makeProvider(
        _ server: BitwardenMockServer,
        allowsSelfSignedTLS: Bool = false,
        masterPassword: String = "test"
    ) throws -> BitwardenVaultProvider {
        BitwardenMockURLProtocol.server = server

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [BitwardenMockURLProtocol.self]

        var configuration = BitwardenVaultProvider.Configuration(
            serverURL: try XCTUnwrap(URL(string: "https://vault.lan")),
            email: "test@bitwarden.com")
        configuration.allowsSelfSignedTLS = allowsSelfSignedTLS

        return try BitwardenVaultProvider(
            configuration: configuration,
            masterPassword: BitwardenVaultProvider.constant(masterPassword),
            sessionConfiguration: sessionConfiguration)
    }

    // MARK: Sync

    func testSyncProducesLoginsFromTheFixture() async throws {
        let server = BitwardenServerFixtures.vault()
        let provider = try makeProvider(server)

        let logins = try await provider.allLogins()
        XCTAssertEqual(logins.map(\.title), ["GitHub", "Homelab router"])

        let github = try XCTUnwrap(logins.first)
        XCTAssertEqual(github.id.rawValue, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(github.username, "andy@example.com")
        XCTAssertEqual(github.password, "correct-horse-battery-staple")
        XCTAssertEqual(github.totp, "JBSWY3DPEHPK3PXP")
        // The folder name is itself an EncString, so a vault subtitle proves
        // the folder table was decrypted too.
        XCTAssertEqual(github.vaultName, "Personal")
        XCTAssertTrue(github.hasSecrets)
        // Vaultwarden sends seven fractional digits, which
        // `ISO8601DateFormatter` rejects outright — so assert the date really
        // parsed rather than that two nils are equal.
        XCTAssertNotNil(github.updatedAt)
        XCTAssertEqual(
            github.updatedAt,
            BitwardenDate.parse("2026-09-14T12:00:00.0000000Z"))

        let router = logins[1]
        XCTAssertEqual(router.username, "admin")
        XCTAssertEqual(router.password, "hunter2-but-longer")
        XCTAssertNil(router.totp)
        XCTAssertNil(router.vaultName)

        let unlocked = await provider.isUnlocked
        XCTAssertTrue(unlocked)
    }

    func testOnlyLoginCiphersBecomeLogins() async throws {
        let provider = try makeProvider(BitwardenServerFixtures.vault())
        let titles = try await provider.allLogins().map(\.title)

        // A secure note (type 2) and an identity (type 4) are perfectly
        // readable with our key — they are excluded because they are not
        // logins, not because they failed to decrypt.
        XCTAssertFalse(titles.contains("A secure note"))
        XCTAssertFalse(titles.contains("An identity"))
        // Items in the trash still arrive in /api/sync.
        XCTAssertFalse(titles.contains("Deleted login"))
        XCTAssertEqual(titles.count, 2)
    }

    func testOrganisationItemsAreSkippedAndCounted() async throws {
        let provider = try makeProvider(BitwardenServerFixtures.vault())
        let logins = try await provider.allLogins()

        // The org cipher is encrypted under a key we never unwrap, so it fails
        // its MAC check. The whole sync must survive that.
        XCTAssertFalse(logins.contains { $0.title == "Shared billing" })
        let skipped = await provider.skippedItemCount
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(logins.count, 2)
    }

    func testURIMatchTypesMapOntoBitwardensRawValues() async throws {
        let provider = try makeProvider(BitwardenServerFixtures.vault())
        let logins = try await provider.allLogins()

        XCTAssertEqual(
            logins[0].uris,
            [
                // A null `match` means "the account default", which Bitwarden
                // ships as base-domain matching.
                VaultURI(uri: "https://github.com/login", match: .domain),
                VaultURI(uri: "github.com", match: .host),
            ])
        XCTAssertEqual(logins[1].uris, [VaultURI(uri: "https://10.0.0.1/", match: .exact)])
    }

    // MARK: Sign-in

    func testTheMasterPasswordIsNeverSent() async throws {
        let server = BitwardenServerFixtures.vault()
        let provider = try makeProvider(server)
        _ = try await provider.allLogins()

        let token = try XCTUnwrap(
            server.requests.first { $0.path.hasSuffix("/connect/token") })
        let body = token.bodyText
        XCTAssertTrue(body.contains("grant_type=password"), body)
        XCTAssertTrue(body.contains("scope=api%20offline_access"), body)
        XCTAssertTrue(body.contains("client_id=browser"), body)
        // "+", "/" and "=" all appear in a base64 hash and all mean something
        // else in a form body.
        XCTAssertFalse(body.contains("+"), body)
        XCTAssertFalse(body.contains("password=test&"), "the master password must never be sent")
        XCTAssertFalse(
            body.hasSuffix("password=test"), "the master password must never be sent")
    }

    func testUnauthorizedSurfacesAsAServerError() async throws {
        let server = BitwardenServerFixtures.vault(
            token: BitwardenServerFixtures.invalidGrantJSON,
            tokenStatus: 401)
        let provider = try makeProvider(server)

        do {
            _ = try await provider.allLogins()
            XCTFail("expected the sign-in to fail")
        } catch let error as VaultError {
            guard case .server(let status, let message) = error else {
                return XCTFail("expected a server error, got \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertTrue(message.contains("incorrect"), message)
            // The sentence the user sees has to name the code.
            XCTAssertTrue(
                error.errorDescription?.contains("401") ?? false,
                error.errorDescription ?? "nil")
        }

        let unlocked = await provider.isUnlocked
        XCTAssertFalse(unlocked)
    }

    func testAServerThatServesTheServicesAtTheRootStillWorks() async throws {
        // A 404 on /identity/accounts/prelogin demotes the client to root
        // paths for the rest of the session rather than reporting a broken
        // server. Everything after it must go to the root form too.
        let server = BitwardenServerFixtures.vault(servesAtRoot: true)
        let provider = try makeProvider(server)

        let logins = try await provider.allLogins()
        XCTAssertEqual(logins.count, 2)
        XCTAssertTrue(server.requests.contains { $0.path == "/identity/accounts/prelogin" })
        XCTAssertTrue(server.requests.contains { $0.path == "/accounts/prelogin" })
        XCTAssertTrue(server.requests.contains { $0.path == "/sync" })
        XCTAssertFalse(server.requests.contains { $0.path == "/api/sync" })
    }

    func testSelfSignedOptInStillReachesTheServer() async throws {
        // The opt-in adds a `URLSessionDelegate`, which changes how the session
        // is constructed; a stub protocol never presents a certificate, so this
        // only proves the delegate wiring did not break the session.
        let provider = try makeProvider(
            BitwardenServerFixtures.vault(), allowsSelfSignedTLS: true)
        let logins = try await provider.allLogins()
        XCTAssertEqual(logins.count, 2)
    }

    // MARK: Reveal

    func testRevealComesFromTheBulkSyncRatherThanAnotherRequest() async throws {
        let server = BitwardenServerFixtures.vault()
        let provider = try makeProvider(server)

        let logins = try await provider.allLogins()
        let before = server.requests.count

        let revealed = try await provider.reveal(try XCTUnwrap(logins.first).id)
        XCTAssertEqual(revealed.password, "correct-horse-battery-staple")
        XCTAssertEqual(revealed.totp, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(
            server.requests.count, before,
            "/api/sync already carried the secret; asking again would leak which login was used")
    }

    func testRevealingSomethingThatIsNotThereSaysSo() async throws {
        let provider = try makeProvider(BitwardenServerFixtures.vault())
        do {
            _ = try await provider.reveal(VaultItemID("not-a-real-id"))
            XCTFail("expected a not-found error")
        } catch let error as VaultError {
            guard case .notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    // MARK: Writing

    func testCreateLoginSendsEncryptedFieldsAndReturnsTheStoredItem() async throws {
        let server = BitwardenServerFixtures.vault()
        let provider = try makeProvider(server)
        _ = try await provider.allLogins()

        let draft = VaultLoginDraft(
            title: "Example",
            username: "andy",
            password: "s3cret-and-long-enough",
            uri: "https://example.com/login")
        let created = try await provider.createLogin(draft)

        XCTAssertEqual(created.id.rawValue, "99999999-8888-7777-6666-555555555555")
        XCTAssertEqual(created.title, "Example")
        XCTAssertEqual(created.username, "andy")
        XCTAssertEqual(created.password, "s3cret-and-long-enough")
        XCTAssertEqual(created.uris, [VaultURI(uri: "https://example.com/login", match: .domain)])

        let write = try XCTUnwrap(
            server.requests.first { $0.method == "POST" && $0.path.hasSuffix("/api/ciphers") })
        let body = write.bodyText
        // Type 1 (Login), and not one readable field on the wire.
        XCTAssertTrue(body.contains("\"type\":1"), body)
        XCTAssertFalse(body.contains("Example"), body)
        XCTAssertFalse(body.contains("s3cret"), body)
        XCTAssertFalse(body.contains("example.com"), body)
        XCTAssertTrue(body.contains("\"2."), "every string field should be an EncString: \(body)")
    }

    func testUpdateLoginPutsToTheItemsOwnURL() async throws {
        let server = BitwardenServerFixtures.vault()
        let provider = try makeProvider(server)
        let logins = try await provider.allLogins()
        let github = try XCTUnwrap(logins.first)

        let updated = try await provider.updateLogin(
            github.id,
            with: VaultLoginDraft(
                title: "GitHub",
                username: "andy@example.com",
                password: "rotated-password-2026",
                uri: "https://github.com/login"))

        XCTAssertEqual(updated.id, github.id)
        XCTAssertEqual(updated.password, "rotated-password-2026")
        // The item keeps the folder it was already in.
        XCTAssertEqual(updated.vaultName, "Personal")

        let write = try XCTUnwrap(server.requests.first { $0.method == "PUT" })
        XCTAssertEqual(write.path, "/api/ciphers/11111111-2222-3333-4444-555555555555")
        XCTAssertFalse(write.bodyText.contains("rotated-password-2026"), write.bodyText)
    }

    // MARK: Session

    func testVerifyConnectionSummarisesTheAccountAndItsFolders() async throws {
        let provider = try makeProvider(BitwardenServerFixtures.vault())
        let summaries = try await provider.verifyConnection()

        XCTAssertEqual(summaries.first?.name, "test@bitwarden.com")
        XCTAssertEqual(summaries.first?.itemCount, 2)
        XCTAssertEqual(summaries.dropFirst().map(\.name), ["Personal"])
        XCTAssertEqual(summaries.dropFirst().first?.itemCount, 1)
    }

    func testLockForgetsTheKeyAndSignsInAgainAfterwards() async throws {
        let server = BitwardenServerFixtures.vault()
        let provider = try makeProvider(server)
        _ = try await provider.allLogins()
        let unlockedBefore = await provider.isUnlocked
        XCTAssertTrue(unlockedBefore)

        await provider.lock()
        let unlockedAfter = await provider.isUnlocked
        XCTAssertFalse(unlockedAfter)
        let skipped = await provider.skippedItemCount
        XCTAssertEqual(skipped, 0)

        // Locking is not a logout: the next call signs in again by itself, so
        // it must have asked for the KDF parameters a second time.
        _ = try await provider.allLogins()
        XCTAssertEqual(server.requests(matching: "prelogin").count, 2)
        let unlockedAgain = await provider.isUnlocked
        XCTAssertTrue(unlockedAgain)
    }

    func testProviderIdentityIsReadableWithoutAwaiting() throws {
        let provider = try makeProvider(BitwardenServerFixtures.vault())
        // Both are `nonisolated` so a settings row can render them without
        // hopping onto the actor mid-layout.
        XCTAssertEqual(provider.kind, .bitwarden)
        XCTAssertEqual(provider.serverDescription, "vault.lan")
    }

    // MARK: Encoding

    func testFormEncodingEscapesBase64Characters() {
        // A "+" in a form body decodes as a space, and "+" is one of base64's
        // 64 characters — so an unescaped master password hash silently becomes
        // the wrong hash roughly half the time, and the user is told their
        // password is wrong.
        let encoded = BitwardenAPIClient.formURLEncoded([
            "password": "/fLMc6m0bwpU1bYko8NY/gl/+SaxfSGGQc6arJoDOaE=",
            "grant_type": "password",
        ])
        XCTAssertTrue(encoded.contains("%2B"), encoded)
        XCTAssertTrue(encoded.contains("%2F"), encoded)
        XCTAssertTrue(encoded.contains("%3D"), encoded)
        XCTAssertFalse(encoded.contains("+"), encoded)
    }
}
