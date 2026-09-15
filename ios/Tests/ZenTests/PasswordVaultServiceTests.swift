//  PasswordVaultServiceTests.swift
//  The policy half of the vault — matching, caching, and when to ask (#008AD).
//
//  Every test here runs against a **stub provider**. That is not a shortcut: no
//  1Password Connect server and no Vaultwarden instance is reachable from the
//  machine this is developed on, and a test that needed one would be a test
//  that never ran. The two real backends are exercised against mocked HTTP in
//  `BitwardenProviderTests` and `OnePasswordConnectTests`; what is left — and
//  what this file covers — is everything that is the *app's* decision rather
//  than the server's.
//
//  The sealed index and the keychain are also doubled, for a plainer reason:
//  the simulator's keychain is shared by every test in the process, so a test
//  that wrote real items would leak into the next one.

import XCTest

@testable import Zen

// MARK: - Stub

/// A provider that answers from a script rather than a server.
actor StubVaultProvider: PasswordVaultProvider {
    nonisolated let kind: VaultProviderKind
    nonisolated let serverDescription = "stub"

    var isUnlocked = true

    var logins: [VaultLogin]
    var vaults: [VaultSummary]
    var failure: VaultError?
    /// Counted so the throttle and the coalescing can be asserted on rather
    /// than assumed.
    private(set) var allLoginsCallCount = 0
    private(set) var created: [VaultLoginDraft] = []
    private(set) var updated: [(VaultItemID, VaultLoginDraft)] = []

    init(
        kind: VaultProviderKind = .bitwarden,
        logins: [VaultLogin] = [],
        vaults: [VaultSummary] = [VaultSummary(id: "v", name: "Personal", itemCount: 0)],
        failure: VaultError? = nil
    ) {
        self.kind = kind
        self.logins = logins
        self.vaults = vaults
        self.failure = failure
    }

    func verifyConnection() async throws -> [VaultSummary] {
        if let failure { throw failure }
        return vaults
    }

    func allLogins() async throws -> [VaultLogin] {
        allLoginsCallCount += 1
        if let failure { throw failure }
        return logins
    }

    func reveal(_ id: VaultItemID) async throws -> VaultLogin {
        if let failure { throw failure }
        guard let login = logins.first(where: { $0.id == id }) else {
            throw VaultError.notFound(id.rawValue)
        }
        return login
    }

    func createLogin(_ draft: VaultLoginDraft) async throws -> VaultLogin {
        if let failure { throw failure }
        created.append(draft)
        let login = VaultLogin(
            id: VaultItemID("new-\(created.count)"),
            title: draft.title, username: draft.username, password: draft.password,
            uris: [VaultURI(uri: draft.uri)])
        logins.append(login)
        return login
    }

    func updateLogin(_ id: VaultItemID, with draft: VaultLoginDraft) async throws -> VaultLogin {
        if let failure { throw failure }
        updated.append((id, draft))
        let login = VaultLogin(
            id: id, title: draft.title, username: draft.username, password: draft.password,
            uris: [VaultURI(uri: draft.uri)])
        if let index = logins.firstIndex(where: { $0.id == id }) { logins[index] = login }
        return login
    }

    func lock() async { isUnlocked = false }
}

// MARK: - Tests

@MainActor
final class PasswordVaultServiceTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles = []
        super.tearDown()
    }

    // MARK: Sync and the index

    func testSyncBuildsAnIndexAndRecordsWhenItHappened() async throws {
        let provider = StubVaultProvider(logins: [github(), homelab()])
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let service = makeService(provider: provider, now: clock.now)

        await service.sync()

        XCTAssertEqual(service.entries.count, 2)
        XCTAssertEqual(service.lastSyncItemCount, 2)
        XCTAssertEqual(service.lastSyncedAt, Date(timeIntervalSince1970: 1_000_000))
        XCTAssertNil(service.lastError)
    }

    /// The point of the whole file: what lands on disk has no passwords in it.
    func testTheIndexNeverHoldsASecret() async throws {
        let indexURL = temporaryURL(extension: "sealed")
        let credentials = InMemoryVaultCredentialStore(
            credentials: VaultCredentials(masterPassword: "master"))
        let store = VaultIndexStore(credentials: credentials, url: indexURL)
        let service = makeService(
            provider: StubVaultProvider(logins: [github()]),
            credentialStore: credentials, indexStore: store)

        await service.sync()

        // The entry knows a second factor exists without holding it.
        let entry = try XCTUnwrap(service.entries.first)
        XCTAssertTrue(entry.hasTOTP)
        XCTAssertEqual(entry.username, "andy")
        XCTAssertNil(entry.login.password)
        XCTAssertNil(entry.login.totp)

        // And the bytes on disk are sealed, so neither the password nor the
        // TOTP secret is recoverable by reading the file.
        let raw = try Data(contentsOf: indexURL)
        XCTAssertFalse(
            String(decoding: raw, as: UTF8.self).contains("hunter2"),
            "a password reached the index file")
        XCTAssertFalse(
            String(decoding: raw, as: UTF8.self).contains("github.com"),
            "the index is not encrypted at rest")

        // Round trip: it opens again with the same key.
        let reopened = try XCTUnwrap(store.load())
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertNil(reopened.entries[0].login.password)
    }

    func testAnIndexSealedWithAnotherKeyIsDiscardedRatherThanTrusted() throws {
        let url = temporaryURL(extension: "sealed")
        let first = InMemoryVaultCredentialStore()
        try VaultIndexStore(credentials: first, url: url).save(
            logins: [github()], providerKind: .bitwarden, secretsCached: true)

        // A different keychain means a different key — the file is unreadable,
        // and saying so beats silently showing an empty vault.
        let second = InMemoryVaultCredentialStore()
        XCTAssertThrowsError(try VaultIndexStore(credentials: second, url: url).load()) { error in
            XCTAssertEqual(error as? VaultIndexStore.Failure, .unreadable)
        }
    }

    func testASyncFailureIsReportedAndLeavesTheOldIndexAlone() async throws {
        let provider = StubVaultProvider(logins: [github()])
        let service = makeService(provider: provider)
        await service.sync()
        XCTAssertEqual(service.entries.count, 1)

        await provider.setFailure(.server(status: 401, message: "Invalid password"))
        await service.sync()

        XCTAssertEqual(service.entries.count, 1, "a failed sync emptied the cache")
        XCTAssertEqual(service.lastError, "The vault server answered 401: Invalid password")
    }

    /// A foreground sync a minute after the last one is a waste of a KDF run.
    func testForegroundSyncIsThrottled() async throws {
        let provider = StubVaultProvider(logins: [github()])
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let service = makeService(provider: provider, now: clock.now)

        await service.sync()
        let afterFirst = await provider.allLoginsCallCount

        clock.advance(by: 60)
        await service.syncIfStale()
        // Hoisted out of the assertion: `await` is not allowed inside an
        // autoclosure, which is what XCTAssert's arguments are.
        let afterThrottled = await provider.allLoginsCallCount
        XCTAssertEqual(afterThrottled, afterFirst, "a sync ran a minute after the last")

        clock.advance(by: PasswordVaultService.foregroundSyncInterval)
        await service.syncIfStale()
        let afterStale = await provider.allLoginsCallCount
        XCTAssertEqual(afterStale, afterFirst + 1)
    }

    // MARK: Matching

    func testMatchingEntriesCarryTheDisplayFactsTheLoginDoesNot() async throws {
        let service = makeService(provider: StubVaultProvider(logins: [github(), homelab()]))
        await service.sync()

        let matches = service.matchingEntries(for: URL(string: "https://github.com/login")!)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.title, "GitHub")
        XCTAssertEqual(matches.first?.hasTOTP, true)
    }

    func testSearchLooksAtTitleUsernameAndDomain() async throws {
        let service = makeService(provider: StubVaultProvider(logins: [github(), homelab()]))
        await service.sync()

        XCTAssertEqual(service.search("git").map(\.title), ["GitHub"])
        XCTAssertEqual(service.search("vault.lan").map(\.title), ["Vaultwarden"])
        XCTAssertEqual(service.search("andy").count, 2)
        XCTAssertEqual(service.search("").count, 2)
    }

    // MARK: The save prompt

    func testARegistrationFormNeverRaisesASavePrompt() async throws {
        let service = makeService(provider: StubVaultProvider())
        await service.sync()
        service.noteSubmittedCredential(
            credential(url: "https://example.com/signup", isRegistration: true))
        XCTAssertNil(service.pendingSave, "a sign-up form offered to save an unaccepted password")
    }

    func testASubmittedCredentialOnAnUnknownSiteOffersToCreate() async throws {
        let service = makeService(provider: StubVaultProvider(logins: [github()]))
        await service.sync()
        let submitted = credential(url: "https://example.com/login")
        service.noteSubmittedCredential(submitted)
        XCTAssertNotNil(service.pendingSave)
        XCTAssertNil(service.existingEntry(for: submitted), "an unrelated site matched")
    }

    /// Same site *and* same username is an update; that is what keeps a vault
    /// from growing three entries for one login.
    func testAMatchingUsernameOnAKnownSiteIsAnUpdate() async throws {
        let service = makeService(provider: StubVaultProvider(logins: [github()]))
        await service.sync()
        let submitted = credential(
            url: "https://github.com/session", username: "andy", password: "new-password")
        let existing = service.existingEntry(for: submitted)
        XCTAssertEqual(existing?.id, VaultItemID("gh"))
    }

    /// A second account on a site someone already has a login for is a new
    /// entry, not an overwrite of the first.
    func testADifferentUsernameOnAKnownSiteIsNotAnUpdate() async throws {
        let service = makeService(provider: StubVaultProvider(logins: [github()]))
        await service.sync()
        let submitted = credential(
            url: "https://github.com/session", username: "someone-else", password: "x")
        XCTAssertNil(service.existingEntry(for: submitted))
    }

    func testCreateAndUpdateReachTheProvider() async throws {
        let provider = StubVaultProvider(logins: [github()])
        let service = makeService(provider: provider)
        await service.sync()

        _ = try await service.createLogin(
            VaultLoginDraft(
                title: "Example", username: "andy", password: "p", uri: "https://example.com"))
        _ = try await service.updateLogin(
            VaultItemID("gh"),
            with: VaultLoginDraft(
                title: "GitHub", username: "andy", password: "p2", uri: "https://github.com"))

        let created = await provider.created
        let updated = await provider.updated
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.0, VaultItemID("gh"))
    }

    // MARK: Forgetting

    func testForgettingRemovesTheCredentialsTheIndexAndItsKey() async throws {
        let indexURL = temporaryURL(extension: "sealed")
        let credentials = InMemoryVaultCredentialStore(
            credentials: VaultCredentials(masterPassword: "master"))
        let service = makeService(
            provider: StubVaultProvider(logins: [github()]),
            credentialStore: credentials,
            indexStore: VaultIndexStore(credentials: credentials, url: indexURL))
        await service.sync()
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))

        service.forgetVault()

        XCTAssertFalse(service.isConfigured)
        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertNil(credentials.loadCredentials())
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
    }

    // MARK: Server URLs

    /// A vault credential over cleartext is not something to make easy.
    func testOnlyHTTPSServersAreAccepted() throws {
        XCTAssertEqual(try VaultProviderFactory.serverURL(from: "vault.lan").scheme, "https")
        XCTAssertEqual(
            try VaultProviderFactory.serverURL(from: "https://vault.lan:8443").port, 8443)
        XCTAssertThrowsError(try VaultProviderFactory.serverURL(from: "http://vault.lan"))
        XCTAssertThrowsError(try VaultProviderFactory.serverURL(from: "   "))
    }

    // MARK: Helpers

    private func github() -> VaultLogin {
        VaultLogin(
            id: VaultItemID("gh"), title: "GitHub", username: "andy", password: "hunter2",
            totp: "otpauth://totp/GitHub:andy?secret=GEZDGNBVGY3TQOJQ",
            uris: [VaultURI(uri: "https://github.com")])
    }

    private func homelab() -> VaultLogin {
        VaultLogin(
            id: VaultItemID("vw"), title: "Vaultwarden", username: "andy@example.com",
            password: "correct-horse", uris: [VaultURI(uri: "https://vault.lan")])
    }

    private func credential(
        url: String, username: String? = "andy", password: String = "hunter2",
        isRegistration: Bool = false
    ) -> SubmittedCredential {
        SubmittedCredential(messageBody: [
            "username": username as Any,
            "password": password,
            "url": url,
            "title": "Sign in",
            "isLikelyRegistration": isRegistration,
        ])!
    }

    private func temporaryURL(extension ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-vault-\(UUID().uuidString).\(ext)")
        temporaryFiles.append(url)
        return url
    }

    private func makeService(
        provider: StubVaultProvider,
        credentialStore: InMemoryVaultCredentialStore? = nil,
        indexStore: VaultIndexStore? = nil,
        now: (() -> Date)? = nil
    ) -> PasswordVaultService {
        let credentials =
            credentialStore
            ?? InMemoryVaultCredentialStore(
                credentials: VaultCredentials(masterPassword: "master"))
        let service = PasswordVaultService(
            credentialStore: credentials,
            configurationStore: .init(url: temporaryURL(extension: "json")),
            indexStore: indexStore
                ?? VaultIndexStore(
                    credentials: credentials, url: temporaryURL(extension: "sealed")),
            makeProvider: { _, _ in provider },
            now: now ?? { Date() })
        service.configure(
            VaultConfiguration(
                kind: provider.kind, serverURL: "https://vault.lan",
                accountEmail: "andy@example.com", requiresBiometrics: false),
            credentials: VaultCredentials(masterPassword: "master"))
        return service
    }
}

// MARK: - A clock that can be pushed

/// `Date()` is not a thing a test can move, and the throttle is defined in
/// terms of elapsed time.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: () -> Date {
        { [self] in lock.withLock { current } }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

extension StubVaultProvider {
    func setFailure(_ failure: VaultError?) { self.failure = failure }
}
