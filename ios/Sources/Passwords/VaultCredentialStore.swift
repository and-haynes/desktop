//  VaultCredentialStore.swift
//  Where the vault's credentials live, and where the cached index's key lives
//  (#008AD).
//
//  Two different secrets with two different jobs, deliberately kept apart:
//
//   1. **Credentials** — a 1Password Connect token, or a Vaultwarden email and
//      master password. Anything holding these can read the whole vault, so
//      they go in the keychain and nowhere else, with
//      `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
//   2. **The index key** — a 32-byte AES-GCM key protecting the on-disk
//      domain→item index. Also keychain, also device-only, but a separate item
//      so that "forget my vault" can drop the credentials while the index is
//      cleared independently, and so a bug in one path cannot overwrite the
//      other.
//
//  ## Why `WhenUnlocked` here and `AfterFirstUnlock` for sync
//
//  `SyncAccountStore` uses `AfterFirstUnlock` because a background sync must
//  work with the phone in a pocket. Nothing here runs in the background: a
//  password is fetched because someone is looking at the screen and tapped a
//  row. `WhenUnlocked` is the stricter choice and costs us nothing, so it is
//  the one to take.
//
//  `ThisDeviceOnly` on both: a master password in an iCloud Keychain backup is
//  a different threat model than the one anybody signed up for.

import Foundation
import Security

// MARK: - What is stored

/// The non-secret half of a vault setup — safe in ordinary JSON, and shown on
/// the settings screen.
struct VaultConfiguration: Codable, Equatable, Sendable {
    var kind: VaultProviderKind
    /// `https://vault.lan` or `https://connect.lan:8080`.
    var serverURL: String
    /// Bitwarden only: the account email, which is also the KDF salt.
    var accountEmail: String?
    /// Opt-in, because the homelab's certificates are its own.
    var allowsSelfSignedTLS: Bool
    /// Ask for Face ID before a password is revealed or filled.
    var requiresBiometrics: Bool
    var lastSyncedAt: Date?
    var lastSyncItemCount: Int?
    /// Stable for the life of this connection, and minted once.
    ///
    /// Bitwarden treats a new `deviceIdentifier` as a new device: it opens a
    /// fresh session and, on a real bitwarden.com account, sends a "new device
    /// logged in" email. Generating one per provider construction — which is
    /// once per launch, and again after every settings change — would leave a
    /// trail of dead sessions and a stream of alarming mail. Kept here with the
    /// rest of the non-secret configuration so it survives relaunches.
    var deviceIdentifier: String

    init(
        kind: VaultProviderKind,
        serverURL: String,
        accountEmail: String? = nil,
        allowsSelfSignedTLS: Bool = false,
        requiresBiometrics: Bool = true,
        lastSyncedAt: Date? = nil,
        lastSyncItemCount: Int? = nil,
        deviceIdentifier: String = UUID().uuidString
    ) {
        self.kind = kind
        self.serverURL = serverURL
        self.accountEmail = accountEmail
        self.allowsSelfSignedTLS = allowsSelfSignedTLS
        self.requiresBiometrics = requiresBiometrics
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncItemCount = lastSyncItemCount
        self.deviceIdentifier = deviceIdentifier
    }

    /// Older stored configurations predate `deviceIdentifier`; decoding one
    /// must mint an identifier rather than fail, or a working vault would
    /// disappear on upgrade.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(VaultProviderKind.self, forKey: .kind)
        serverURL = try container.decode(String.self, forKey: .serverURL)
        accountEmail = try container.decodeIfPresent(String.self, forKey: .accountEmail)
        allowsSelfSignedTLS =
            try container.decodeIfPresent(Bool.self, forKey: .allowsSelfSignedTLS) ?? false
        requiresBiometrics =
            try container.decodeIfPresent(Bool.self, forKey: .requiresBiometrics) ?? true
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastSyncItemCount = try container.decodeIfPresent(Int.self, forKey: .lastSyncItemCount)
        deviceIdentifier =
            try container.decodeIfPresent(String.self, forKey: .deviceIdentifier)
            ?? UUID().uuidString
    }
}

/// The secret half — keychain only, never in JSON, never in a log line.
struct VaultCredentials: Codable, Equatable, Sendable {
    /// 1Password Connect.
    var connectToken: String?
    /// Bitwarden / Vaultwarden.
    var masterPassword: String?

    init(connectToken: String? = nil, masterPassword: String? = nil) {
        self.connectToken = connectToken
        self.masterPassword = masterPassword
    }

    var isEmpty: Bool { connectToken == nil && masterPassword == nil }
}

// MARK: - Store

protocol VaultCredentialStoring: Sendable {
    func loadCredentials() -> VaultCredentials?
    /// Returns whether the write actually happened.
    ///
    /// Not `Void`, because the keychain's way of refusing is to return a status
    /// nobody checks. `errSecMissingEntitlement` (-34018) — which is what a
    /// build with no entitlements gets for every call — produced a vault that
    /// connected successfully, displayed its server and account, and then
    /// reported "no password vault is set up yet" on the very next sync. A
    /// failure that cannot be observed is a failure that gets misdiagnosed.
    @discardableResult
    func saveCredentials(_ credentials: VaultCredentials) -> Bool
    func clearCredentials()

    /// The index key, minted on first use. Returns nil only when the keychain
    /// itself refuses, which is not a case worth papering over.
    func indexKey() -> Data?
    func clearIndexKey()
}

struct KeychainVaultCredentialStore: VaultCredentialStoring {
    let service: String

    private static let credentialsAccount = "vault-credentials"
    private static let indexKeyAccount = "vault-index-key"
    private static let indexKeyByteCount = 32

    init(service: String = "app.zen.passwords") {
        self.service = service
    }

    // MARK: Credentials

    func loadCredentials() -> VaultCredentials? {
        guard let data = read(account: Self.credentialsAccount) else { return nil }
        return try? JSONDecoder().decode(VaultCredentials.self, from: data)
    }

    @discardableResult
    func saveCredentials(_ credentials: VaultCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        return write(data, account: Self.credentialsAccount)
    }

    func clearCredentials() {
        delete(account: Self.credentialsAccount)
    }

    // MARK: Index key

    func indexKey() -> Data? {
        if let existing = read(account: Self.indexKeyAccount),
            existing.count == Self.indexKeyByteCount
        {
            return existing
        }
        // Mint on first use rather than at setup: an install that never
        // configures a vault never gets a key it does not need.
        var key = Data(count: Self.indexKeyByteCount)
        let status = key.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, Self.indexKeyByteCount, base)
        }
        guard status == errSecSuccess else { return nil }
        guard write(key, account: Self.indexKeyAccount) else { return nil }
        // Read back rather than trusting the write: if the keychain refused,
        // encrypting an index with a key we cannot retrieve later would lose
        // the cache silently on next launch.
        return read(account: Self.indexKeyAccount)
    }

    func clearIndexKey() {
        delete(account: Self.indexKeyAccount)
    }

    // MARK: Keychain plumbing

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return data
    }

    @discardableResult
    private func write(_ data: Data, account: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let query = baseQuery(account: account)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = query
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// Whether this process can use the keychain at all.
    ///
    /// A build with no entitlements — anything made with
    /// `CODE_SIGNING_ALLOWED=NO` — gets -34018 from every call, so the tests
    /// skip rather than fail and the app can say something true.
    static var isAvailable: Bool {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.zen.keychain-probe",
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data("probe".utf8),
        ]
        SecItemDelete(probe as CFDictionary)
        let status = SecItemAdd(probe as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        return status == errSecSuccess
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

/// In-memory double for tests and previews. The keychain is available in a
/// simulator but shared across every test in the process, so a test that wrote
/// real items would leak into the next one.
final class InMemoryVaultCredentialStore: VaultCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: VaultCredentials?
    private var key: Data?

    init(credentials: VaultCredentials? = nil) {
        self.credentials = credentials
    }

    func loadCredentials() -> VaultCredentials? {
        lock.withLock { credentials }
    }

    @discardableResult
    func saveCredentials(_ credentials: VaultCredentials) -> Bool {
        lock.withLock { self.credentials = credentials }
        return true
    }

    func clearCredentials() {
        lock.withLock { credentials = nil }
    }

    func indexKey() -> Data? {
        lock.withLock {
            if let key { return key }
            var fresh = Data(count: 32)
            _ = fresh.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
            }
            key = fresh
            return fresh
        }
    }

    func clearIndexKey() {
        lock.withLock { key = nil }
    }
}
