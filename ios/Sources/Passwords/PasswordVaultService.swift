//  PasswordVaultService.swift
//  The one object the UI talks to about passwords (#008AD).
//
//  Everything provider-specific is behind `PasswordVaultProvider`; everything
//  policy is here. That split is what keeps the panel, the save prompt and the
//  settings screen from each growing their own idea of when to sync, when to
//  ask for Face ID, and what to do when the vault is unreachable.
//
//  ## When it syncs
//
//  On demand (the panel's pull-to-refresh, the settings screen's button) and on
//  foreground, throttled — not on a timer and not per keystroke. A vault sync
//  is a full item list and, for Bitwarden, a KDF run; doing it because someone
//  opened a tab would be rude to the battery and to `vault.lan`. Between syncs
//  the sealed index answers every match, which is the whole reason it exists.
//
//  ## Failing open on Face ID
//
//  `requiresBiometrics` gates revealing and filling. In a simulator there is no
//  enrolled biometry, and `LAContext.canEvaluatePolicy` says so — in which case
//  the gate **fails open** rather than making the feature untestable on the one
//  machine it is developed on. That is a deliberate and slightly uncomfortable
//  choice, so it is confined to `Biometrics.authenticate`, documented there,
//  and does not apply when biometry exists and merely fails: a wrong face is a
//  refusal, not an absence.

import Combine
import Foundation
import LocalAuthentication

@MainActor
final class PasswordVaultService: ObservableObject {

    // MARK: State

    /// nil until a vault is configured. Published so the settings screen and
    /// the bar action's availability both follow it.
    @Published private(set) var configuration: VaultConfiguration?

    /// The sealed index, in memory. Empty when there is no vault or no sync
    /// has happened yet.
    @Published private(set) var entries: [VaultIndexEntry] = []

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastSyncItemCount: Int?
    @Published private(set) var skippedItemCount = 0

    /// Surfaced by the settings screen and the panel. Cleared when shown.
    @Published var lastError: String?

    /// Raised by the submit observer; drives the save/update sheet.
    @Published var pendingSave: SubmittedCredential?

    // MARK: Collaborators

    private let credentialStore: any VaultCredentialStoring
    private let configurationStore: JSONFileStore<VaultConfiguration>
    private let indexStore: VaultIndexStore
    private let makeProvider: @Sendable (VaultConfiguration, VaultCredentials) throws -> any
        PasswordVaultProvider
    private let now: () -> Date

    private var provider: (any PasswordVaultProvider)?
    private var syncTask: Task<Void, Never>?

    /// Foreground syncs closer together than this are skipped. Long enough that
    /// switching apps repeatedly does not hammer the server, short enough that
    /// a password added on the desktop a minute ago is there.
    static let foregroundSyncInterval: TimeInterval = 5 * 60

    init(
        credentialStore: any VaultCredentialStoring = KeychainVaultCredentialStore(),
        configurationStore: JSONFileStore<VaultConfiguration> = .init(name: "vault.json"),
        indexStore: VaultIndexStore? = nil,
        makeProvider: @escaping @Sendable (VaultConfiguration, VaultCredentials) throws -> any
            PasswordVaultProvider = VaultProviderFactory.make,
        now: @escaping () -> Date = { Date() }
    ) {
        self.credentialStore = credentialStore
        self.configurationStore = configurationStore
        self.indexStore = indexStore ?? VaultIndexStore(credentials: credentialStore)
        self.makeProvider = makeProvider
        self.now = now

        configuration = configurationStore.load()
        lastSyncedAt = configuration?.lastSyncedAt
        lastSyncItemCount = configuration?.lastSyncItemCount
        loadIndex()
    }

    // MARK: Configuration

    var isConfigured: Bool { configuration != nil }

    /// Store a vault setup. The credentials go to the keychain and are not held
    /// here — re-reading them per operation costs a keychain hit and means no
    /// copy of a master password lives in a published object.
    func configure(_ configuration: VaultConfiguration, credentials: VaultCredentials) {
        self.configuration = configuration
        configurationStore.save(configuration)
        credentialStore.saveCredentials(credentials)
        provider = nil
        lastError = nil
    }

    /// Forget the vault entirely: credentials, index, and the key that sealed
    /// it. Three separate removals because they are three separate items, and
    /// a "forget" that leaves one behind is worse than none.
    func forgetVault() {
        Task { await provider?.lock() }
        provider = nil
        configuration = nil
        entries = []
        lastSyncedAt = nil
        lastSyncItemCount = nil
        skippedItemCount = 0
        configurationStore.delete()
        credentialStore.clearCredentials()
        indexStore.clear()
        credentialStore.clearIndexKey()
    }

    /// Flip the Face ID requirement without disturbing anything else on the
    /// configuration — the settings toggle binds straight to this.
    func setRequiresBiometrics(_ required: Bool) {
        guard var configuration else { return }
        configuration.requiresBiometrics = required
        self.configuration = configuration
        configurationStore.save(configuration)
    }

    /// Drop the cache but keep the vault configured.
    func clearCache() {
        indexStore.clear()
        entries = []
        lastSyncedAt = nil
        lastSyncItemCount = nil
        skippedItemCount = 0
        if var configuration {
            configuration.lastSyncedAt = nil
            configuration.lastSyncItemCount = nil
            self.configuration = configuration
            configurationStore.save(configuration)
        }
    }

    // MARK: Matching

    /// Logins for a page, best match first. Pure and synchronous: this runs
    /// while the panel is being laid out.
    func matches(for url: URL) -> [VaultLogin] {
        DomainMatching.matches(for: url, in: entries.map(\.login))
    }

    /// The same answer as `matches(for:)`, but as index entries — which carry
    /// the display-only facts the panel needs (`hasTOTP`, `hasCachedSecret`)
    /// and a `VaultLogin` reconstructed from the index deliberately does not.
    func matchingEntries(for url: URL) -> [VaultIndexEntry] {
        let ranked = DomainMatching.matches(for: url, in: entries.map(\.login))
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { byID[$0.id.rawValue] }
    }

    /// Free-text search across the whole vault, for when the page has no match
    /// or the right entry is filed under another name.
    func search(_ query: String) -> [VaultIndexEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pool =
            trimmed.isEmpty
            ? entries
            : entries.filter { entry in
                entry.title.lowercased().contains(trimmed)
                    || (entry.username?.lowercased().contains(trimmed) ?? false)
                    || entry.domains.contains { $0.contains(trimmed) }
            }
        return pool.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    // MARK: Sync

    /// Sync now. Coalesced: a second call while one is in flight joins it
    /// rather than starting a competing KDF run.
    func sync() async {
        if let syncTask {
            await syncTask.value
            return
        }
        let task = Task { await performSync() }
        syncTask = task
        await task.value
        syncTask = nil
    }

    /// Called when the app comes back to the foreground. Throttled; see
    /// `foregroundSyncInterval`.
    func syncIfStale() async {
        guard isConfigured else { return }
        if let lastSyncedAt, now().timeIntervalSince(lastSyncedAt) < Self.foregroundSyncInterval {
            return
        }
        await sync()
    }

    private func performSync() async {
        guard let configuration else {
            lastError = VaultError.notConfigured.localizedDescription
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let provider = try currentProvider(for: configuration)
            let logins = try await provider.allLogins()
            // Bitwarden's bulk sync carries passwords; Connect's does not. The
            // index strips them either way — this only tells the panel whether
            // tapping a row needs a round trip.
            let secretsCached = logins.contains { $0.hasSecrets }
            let skipped = await provider.skippedItemCount
            let syncedAt = now()
            try indexStore.save(
                logins: logins,
                providerKind: configuration.kind,
                secretsCached: secretsCached,
                skippedCount: skipped,
                at: syncedAt)
            loadIndex()
            lastSyncedAt = syncedAt
            lastSyncItemCount = logins.count
            var updated = configuration
            updated.lastSyncedAt = syncedAt
            updated.lastSyncItemCount = logins.count
            self.configuration = updated
            configurationStore.save(updated)
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Build a provider from a *candidate* setup and ask it to prove itself,
    /// without storing anything. The set-up sheet's "Test and Save" is this
    /// followed by `configure` — in that order, deliberately.
    func testConnection(
        _ configuration: VaultConfiguration, credentials: VaultCredentials
    ) async throws -> [VaultSummary] {
        let candidate = try makeProvider(configuration, credentials)
        return try await candidate.verifyConnection()
    }

    // MARK: Reveal and fill

    /// A login with its secrets, behind the biometric gate.
    ///
    /// Always goes to the provider for Connect, and may for Bitwarden — the
    /// provider decides, because only it knows whether its bulk sync carried
    /// the password.
    func reveal(_ id: VaultItemID, reason: String) async throws -> VaultLogin {
        guard let configuration else { throw VaultError.notConfigured }
        if configuration.requiresBiometrics {
            try await Biometrics.authenticate(reason: reason)
        }
        let provider = try currentProvider(for: configuration)
        return try await provider.reveal(id)
    }

    // MARK: Writing back

    func createLogin(_ draft: VaultLoginDraft) async throws -> VaultLogin {
        guard let configuration else { throw VaultError.notConfigured }
        let provider = try currentProvider(for: configuration)
        let created = try await provider.createLogin(draft)
        await sync()
        return created
    }

    func updateLogin(_ id: VaultItemID, with draft: VaultLoginDraft) async throws -> VaultLogin {
        guard let configuration else { throw VaultError.notConfigured }
        let provider = try currentProvider(for: configuration)
        let updated = try await provider.updateLogin(id, with: draft)
        await sync()
        return updated
    }

    /// The entry a submitted credential should *update* rather than duplicate:
    /// same site, same username. Nil means "offer to create".
    func existingEntry(for credential: SubmittedCredential) -> VaultLogin? {
        let candidates = matches(for: credential.url)
        guard let username = credential.username, !username.isEmpty else {
            // With no username to compare, a single match is still almost
            // certainly the same login; two or more is a guess we should not
            // make on someone's behalf.
            return candidates.count == 1 ? candidates.first : nil
        }
        return candidates.first { $0.username?.caseInsensitiveCompare(username) == .orderedSame }
    }

    /// Handle a credential the page just submitted. Registration forms are
    /// ignored: the "password" there has not been accepted by the site yet, and
    /// saving a password that the signup then rejects is worse than not asking.
    func noteSubmittedCredential(_ credential: SubmittedCredential) {
        guard isConfigured, !credential.isLikelyRegistration else { return }
        // Do not re-prompt for a credential already stored exactly as typed.
        if let existing = existingEntry(for: credential),
            existing.username?.caseInsensitiveCompare(credential.username ?? "") == .orderedSame,
            existing.hasSecrets, existing.password == credential.password
        {
            return
        }
        pendingSave = credential
    }

    // MARK: Plumbing

    private func currentProvider(for configuration: VaultConfiguration) throws -> any
        PasswordVaultProvider
    {
        if let provider, provider.kind == configuration.kind { return provider }
        guard let credentials = credentialStore.loadCredentials(), !credentials.isEmpty else {
            throw VaultError.notConfigured
        }
        let made = try makeProvider(configuration, credentials)
        provider = made
        return made
    }

    private func loadIndex() {
        do {
            guard let snapshot = try indexStore.load() else {
                entries = []
                return
            }
            entries = snapshot.entries
            skippedItemCount = snapshot.skippedCount
            lastSyncedAt = snapshot.syncedAt
            lastSyncItemCount = snapshot.entries.count
        } catch {
            // A cache that will not open is discarded, not mourned. Saying so
            // matters though: the alternative is an empty panel with no reason.
            indexStore.clear()
            entries = []
            lastError = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        if let vaultError = error as? VaultError {
            return vaultError.errorDescription ?? String(describing: vaultError)
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let nsError = error as NSError
        return "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }
}

// MARK: - Biometrics

enum Biometrics {

    enum Failure: LocalizedError, Equatable {
        case denied(String)

        var errorDescription: String? {
            switch self {
            case .denied(let detail): return detail
            }
        }
    }

    /// Face ID / Touch ID, or nothing at all.
    ///
    /// **Fails open when no biometry is enrolled.** A simulator has none, and
    /// the alternative is a feature that cannot be exercised on the machine it
    /// is built on. The distinction that keeps this honest: *absent* biometry
    /// passes, *failed* biometry does not. A device with Face ID set up cannot
    /// be talked past by this path.
    static func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        else {
            // No enrolled biometry, no passcode, or a simulator.
            return
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            guard ok else { throw Failure.denied("Face ID did not confirm.") }
        } catch let laError as LAError where laError.code == .userCancel {
            throw VaultError.cancelled
        } catch {
            throw Failure.denied(error.localizedDescription)
        }
    }
}
