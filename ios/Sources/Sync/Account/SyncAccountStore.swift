//  SyncAccountStore.swift
//  Where the account's secrets live.
//
//  The refresh token and the 64-byte sync key are the account: anything
//  holding both can read every bookmark and every open tab. They go in the
//  keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — after
//  first unlock so a background sync still works, `ThisDeviceOnly` so they are
//  never in an iCloud or iTunes backup.
//
//  The non-secret half (email, device name, which engines are on, when we last
//  synced) is ordinary state and lives in the session's JSON, because losing it
//  is an inconvenience rather than a security event.

import Foundation

/// The secret half — keychain only.
struct SyncSecrets: Codable, Equatable, Sendable {
    var refreshToken: String?
    var accessToken: String?
    var accessTokenExpiresAt: Date?
    var scopedKey: ScopedKey?
    /// Cached token-server allocation. Cheap to re-fetch, but re-fetching on
    /// every sync doubles the round trips.
    var token: TokenServerToken?
    /// Per-collection keys from `crypto/keys`, cached so a sync that changes
    /// nothing costs one request.
    var collectionKeys: CollectionKeys?

    var syncKeyBundle: SyncKeyBundle? { scopedKey?.keyBundle }
}

protocol SyncSecretStoring: Sendable {
    func load() -> SyncSecrets?
    func save(_ secrets: SyncSecrets)
    func clear()
}

/// Keychain-backed. One generic-password item holding a JSON blob: the fields
/// change often enough that one item beats a dozen.
struct KeychainSecretStore: SyncSecretStoring {
    let service: String
    let account: String

    init(service: String = "app.zen.sync", account: String = "mozilla-account") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> SyncSecrets? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(SyncSecrets.self, from: data)
    }

    func save(_ secrets: SyncSecrets) {
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery
            insert.merge(attributes) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// In-memory, for tests and for previews. Deliberately not backed by a file:
/// a test that leaves a refresh token on disk is a bug waiting to be shipped.
final class InMemorySecretStore: SyncSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: SyncSecrets?

    init(_ secrets: SyncSecrets? = nil) {
        self.secrets = secrets
    }

    func load() -> SyncSecrets? {
        lock.lock()
        defer { lock.unlock() }
        return secrets
    }

    func save(_ secrets: SyncSecrets) {
        lock.lock()
        defer { lock.unlock() }
        self.secrets = secrets
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        secrets = nil
    }
}
