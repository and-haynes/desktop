//  VaultIndex.swift
//  The domain→item index that makes the panel instant, encrypted at rest
//  (#008AD).
//
//  Matching a page against a vault is cheap once the vault is in memory and
//  ruinous otherwise: a round trip to `vault.lan` every time the panel opens
//  makes the feature feel broken on a phone, and 1Password Connect would need
//  one request *per item* to answer "which of these match?". So the item list
//  is synced in bulk and kept.
//
//  Kept where, though. A plaintext JSON file listing every site someone has an
//  account with is a meaningful leak even with no passwords in it — it is a map
//  of someone's life, and it would sit in an unencrypted app container backup.
//  So the file is AES-GCM sealed under a key that lives in the keychain
//  (`VaultCredentialStore.indexKey()`), device-only. Lose the key and the index
//  is unreadable, which is the correct outcome: it is a cache and re-syncing
//  rebuilds it.
//
//  ## What is and is not in it
//
//  Titles, usernames, URIs, ids, timestamps — yes. **Passwords and TOTP
//  secrets, never.** They are stripped on the way in, whatever the provider
//  handed over. The panel shows rows from the index and fetches the secret for
//  the one row that gets tapped, so a password's time on disk is nil and its
//  time in memory is the length of a fill. Bitwarden's bulk sync *does* return
//  passwords, so what stops them reaching the disk is that `VaultIndexEntry`
//  has no field to put them in — the stripping is structural rather than a call
//  someone has to remember to make. `hasTOTP` records the *fact* of a second
//  factor for the panel's benefit; the secret behind it stays on the server.

import CryptoKit
import Foundation

// MARK: - Entry

/// One login, as much of it as is safe to keep.
struct VaultIndexEntry: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var username: String?
    var uris: [VaultURI]
    var vaultName: String?
    var updatedAt: Date?
    /// Precomputed at sync time so matching a page is a set lookup rather than
    /// a parse of every URI. Derived, not authoritative — `DomainMatching` is
    /// still what decides a match, this only narrows the candidates.
    var domains: [String]
    /// True when the provider hands secrets over in bulk (Bitwarden), so the
    /// panel knows whether tapping a row needs a round trip (Connect).
    var hasCachedSecret: Bool
    /// Whether the entry carries a second factor — the *fact*, never the
    /// secret. The panel needs it to decide whether to offer a one-time-code
    /// row, and asking the server per row to find out would defeat the index.
    var hasTOTP: Bool

    init(login: VaultLogin, hasCachedSecret: Bool) {
        self.id = login.id.rawValue
        self.title = login.title
        self.username = login.username
        self.uris = login.uris
        self.vaultName = login.vaultName
        self.updatedAt = login.updatedAt
        self.domains = Array(
            Set(login.uris.compactMap { DomainMatching.registrableDomain(ofURLString: $0.uri) })
        ).sorted()
        self.hasCachedSecret = hasCachedSecret
        self.hasTOTP = login.totp?.isEmpty == false
    }

    /// Back to the model the panel and the matcher speak, secrets absent.
    var login: VaultLogin {
        VaultLogin(
            id: VaultItemID(id),
            title: title,
            username: username,
            password: nil,
            totp: nil,
            uris: uris,
            vaultName: vaultName,
            updatedAt: updatedAt)
    }
}

struct VaultIndexSnapshot: Codable, Equatable, Sendable {
    var providerKind: VaultProviderKind
    var syncedAt: Date
    var entries: [VaultIndexEntry]
    /// Items the provider could not read — organisation-encrypted ciphers,
    /// mostly. Surfaced on the settings screen so "why is my work login
    /// missing" has an answer.
    var skippedCount: Int

    init(
        providerKind: VaultProviderKind,
        syncedAt: Date,
        entries: [VaultIndexEntry],
        skippedCount: Int = 0
    ) {
        self.providerKind = providerKind
        self.syncedAt = syncedAt
        self.entries = entries
        self.skippedCount = skippedCount
    }
}

// MARK: - Store

/// Reads and writes the sealed index.
///
/// Not an `ObservableObject` and not `@MainActor`: sealing a few hundred
/// entries is real work and belongs off the main thread, and the caller
/// (`PasswordVaultService`) is the one that publishes.
struct VaultIndexStore: Sendable {
    let url: URL
    let credentials: any VaultCredentialStoring

    init(credentials: any VaultCredentialStoring, url: URL? = nil) {
        self.credentials = credentials
        self.url = url ?? Self.defaultURL
    }

    static var defaultURL: URL {
        let fm = FileManager.default
        let support =
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return
            support
            .appendingPathComponent("Zen", isDirectory: true)
            .appendingPathComponent("vault-index.sealed")
    }

    enum Failure: LocalizedError, Equatable {
        case noKey
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "The keychain would not provide the key that protects the cached vault index."
            case .unreadable:
                return "The cached vault index could not be opened, and has been discarded."
            }
        }
    }

    // MARK: Writing

    /// Seal and write. Secrets are stripped here, not by the caller, so there
    /// is exactly one place to get it right.
    func save(
        logins: [VaultLogin],
        providerKind: VaultProviderKind,
        secretsCached: Bool,
        skippedCount: Int = 0,
        at date: Date = Date()
    ) throws {
        let snapshot = VaultIndexSnapshot(
            providerKind: providerKind,
            syncedAt: date,
            entries: logins.map { VaultIndexEntry(login: $0, hasCachedSecret: secretsCached) },
            skippedCount: skippedCount)
        try save(snapshot)
    }

    func save(_ snapshot: VaultIndexSnapshot) throws {
        guard let keyData = credentials.indexKey() else { throw Failure.noKey }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(snapshot)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData))
        guard let combined = sealed.combined else { throw Failure.unreadable }

        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic, like every other store in the app: a half-written index that
        // fails to open is indistinguishable from a tampered one, and would
        // send someone hunting a security problem that is really a jetsam.
        try combined.write(to: url, options: [.atomic, .completeFileProtection])
    }

    // MARK: Reading

    /// Open the index, or nil when there is not one. A *corrupt* index throws,
    /// because silently returning nil would hide a real problem behind a
    /// spurious empty panel.
    func load() throws -> VaultIndexSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let keyData = credentials.indexKey() else { throw Failure.noKey }
        let combined = try Data(contentsOf: url)
        guard let box = try? AES.GCM.SealedBox(combined: combined),
            let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: keyData))
        else {
            throw Failure.unreadable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VaultIndexSnapshot.self, from: plaintext)
    }

    /// Forget everything cached. Not the same as forgetting the vault — the
    /// credentials survive, and the next sync rebuilds this.
    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
