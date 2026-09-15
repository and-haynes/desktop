//  BitwardenLiveMockTests.swift
//  The Bitwarden provider against a server, over a real socket (#008AD).
//
//  Every other test of this provider mocks `URLProtocol`, which is the right
//  thing for a suite that has to run anywhere — no Vaultwarden is reachable
//  from the machine this app is built on. But mocking the transport also means
//  the transport is never exercised, and the transport is where a surprising
//  amount of reality lives: TLS policy, redirects, form encoding, keep-alive.
//
//  So this is the one test that talks to something. `Tests/Fixtures/mock-
//  vaultwarden.py` speaks the three endpoints the client calls and encrypts its
//  vault the way a real server does — a genuine PBKDF2 run, a genuine HKDF
//  stretch, a genuine user-key unwrap and genuine AES-256-CBC-then-HMAC on
//  every field. Nothing inside the app is stubbed, so this is what says the
//  crypto ported from Ghostty is actually right end to end rather than
//  self-consistent.
//
//  **Skipped, not failed, when the server is absent.** It needs a process
//  running on the host, and a suite that goes red on a machine without one is a
//  suite people learn to ignore:
//
//      python3 Tests/Fixtures/serve.py            # mints the CA, once
//      xcrun simctl keychain booted add-root-cert /tmp/zensync-fixtures/ca.pem
//      python3 Tests/Fixtures/mock-vaultwarden.py
//
//  One thing this caught that no mocked test could: Apple's TLS policy rejects
//  a leaf certificate valid for more than 398 days, inside the security
//  framework and *before* any `URLSessionDelegate` runs — so "allow a
//  self-signed certificate" cannot override it. The fixture CA used to mint
//  ten-year leaves, which loaded fine in a WKWebView and failed every
//  URLSession request with a bare "A TLS error caused the secure connection to
//  fail". `serve.py` now mints 397-day leaves.

import XCTest

@testable import Zen

final class BitwardenLiveMockTests: XCTestCase {

    /// The ports `mock-vaultwarden.py` may be on, probed in order — the port is
    /// the host's to choose and a hard-coded one fails for reasons that have
    /// nothing to do with the app.
    private static let candidateServers = [
        "https://zen.localtest.me:8445",
        "https://zen.localtest.me:8446",
    ]

    private static let email = "andy@example.com"
    private static let masterPassword = "correct-horse-battery-staple"

    /// The whole path: prelogin, PBKDF2, the master password hash, the token
    /// exchange, the user-key unwrap, and decrypting every cipher.
    func testTheProviderReadsAVaultOverTheNetwork() async throws {
        let logins = try await liveLogins()

        // The fixture holds nine ciphers. Six are readable logins; the other
        // three are each a rule this provider is supposed to apply.
        XCTAssertEqual(
            logins.map(\.title),
            ["GitHub", "Vaultwarden", "Homelab router", "Proxmox", "Zen fixture login", "Tickets"])

        let github = try XCTUnwrap(logins.first { $0.title == "GitHub" })
        XCTAssertEqual(github.username, "andy")
        XCTAssertEqual(github.password, "hunter2-github")
        XCTAssertEqual(github.uris.first?.uri, "https://github.com")
        XCTAssertEqual(github.vaultName, "Homelab", "the folder name did not decrypt")
    }

    /// The three exclusions, named individually so a regression says which.
    func testTheUnreadableAndTheDeletedAreLeftOut() async throws {
        let logins = try await liveLogins()
        XCTAssertNil(
            logins.first { $0.title == "Shared billing" },
            "an organisation cipher was offered as a login")
        XCTAssertNil(
            logins.first { $0.title == "Old account" }, "a trashed cipher was offered")
        XCTAssertNil(
            logins.first { $0.title == "A note" }, "a secure note was offered as a login")
    }

    /// A second factor survives the round trip as a usable otpauth URI, which
    /// is the point of storing it at all.
    func testATOTPSecretDecryptsIntoSomethingUsable() async throws {
        let logins = try await liveLogins()
        let github = try XCTUnwrap(logins.first { $0.title == "GitHub" })
        let stored = try XCTUnwrap(github.totp)
        let configuration = try TOTPGenerator.configuration(from: stored)
        XCTAssertEqual(configuration.issuer, "GitHub")
        XCTAssertEqual(TOTPGenerator.code(for: configuration).count, 6)
    }

    /// A wrong master password must fail as a refusal from the server, not as
    /// a crypto error — the derived hash simply will not match.
    func testAWrongMasterPasswordIsRefused() async throws {
        let server = try await reachableServer()
        let provider = try makeProvider(server: server, masterPassword: "not-the-password")
        do {
            _ = try await provider.allLogins()
            XCTFail("a wrong master password was accepted")
        } catch let error as VaultError {
            guard case .server(let status, _) = error else {
                return XCTFail("expected a server refusal, got \(error)")
            }
            XCTAssertEqual(status, 400)
        }
    }

    // MARK: Plumbing

    private func liveLogins() async throws -> [VaultLogin] {
        let server = try await reachableServer()
        return try await makeProvider(server: server).allLogins()
    }

    private func makeProvider(server: String, masterPassword: String? = nil) throws
        -> any PasswordVaultProvider
    {
        try VaultProviderFactory.make(
            VaultConfiguration(
                kind: .bitwarden, serverURL: server, accountEmail: Self.email,
                allowsSelfSignedTLS: true),
            credentials: VaultCredentials(
                masterPassword: masterPassword ?? Self.masterPassword))
    }

    /// The first candidate that answers `prelogin`, or a skip.
    private func reachableServer() async throws -> String {
        for candidate in Self.candidateServers {
            guard let url = URL(string: candidate + "/identity/accounts/prelogin") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 3
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{\"email\":\"\(Self.email)\"}".utf8)
            let session = URLSession(configuration: .ephemeral)
            if let (_, response) = try? await session.data(for: request),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                return candidate
            }
        }
        throw XCTSkip(
            "no mock Vaultwarden on \(Self.candidateServers.joined(separator: " or ")) — "
                + "see this file's header")
    }
}
