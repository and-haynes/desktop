//  BitwardenVaultProvider.swift
//  `PasswordVaultProvider` over Bitwarden's API — which in this house means
//  the homelab's Vaultwarden at https://vault.lan (#008AD).
//
//  Ported from Ghostty's `BitwardenSyncProvider`, which syncs SSH identities
//  and a host list through the same account. That one reads cipher type 5 (SSH
//  key) and type 2 (secure note); this one reads type **1 (Login)** and maps
//  it to `VaultLogin` — URIs with their match rules, username, password, TOTP.
//  The crypto and the REST client underneath are shared in spirit and were
//  ported alongside; only this layer is genuinely different.
//
//  ## Why it is shaped like this
//
//  **Bulk, not per-item.** `GET /api/sync` returns the entire vault with every
//  secret already in it, encrypted under one key. That is the opposite of
//  1Password Connect, where listing and revealing are separate round trips,
//  and it is why `reveal(_:)` here is a cache read rather than a request: a
//  round trip to fetch something we already decoded would be pure latency and
//  would tell the server which login the user just used.
//
//  **One unreadable item must not cost the user their vault.** Ciphers owned
//  by an *organisation* are encrypted with that organisation's key, which
//  arrives RSA-wrapped under the account's private key. Zen does not unwrap org
//  keys — no RSA in the crypto layer, and shared vaults are not what this
//  feature is for — so those items are unreadable by construction. They are
//  counted and skipped, never thrown, and `skippedItemCount` exists so the
//  settings screen can say "3 items in shared collections were skipped"
//  instead of quietly showing a short list.
//
//  **The master password is fetched, not held.** The protocol has no `unlock`
//  entry point, so this takes a closure that produces the master password —
//  from the Keychain behind Face ID, typically. `lock()` drops the derived user
//  key *and* the session token; the next call asks the closure again, which is
//  what makes locking mean something. A convenience initialiser takes a plain
//  `String` for tests and for a one-shot "Test connection", and that one
//  genuinely cannot forget the password — which is why it is not the default.

import Foundation

/// Produces the account's master password on demand. Async and throwing
/// because the real implementation is a Keychain read behind a biometric
/// prompt, which can take a second and can be declined.
typealias BitwardenMasterPasswordSource = @Sendable () async throws -> String

actor BitwardenVaultProvider: PasswordVaultProvider {

    struct Configuration {
        /// `https://vault.lan` for the homelab. `/identity` and `/api` are
        /// appended as Vaultwarden serves them; see `BitwardenEndpoints` for
        /// the servers where that is not true.
        var serverURL: URL
        var email: String
        /// Off by default. Read `BitwardenTLSDelegate` before turning it on:
        /// it trades away the guarantee that you are talking to your server.
        var allowsSelfSignedTLS: Bool = false
        /// A second factor, when the account has one. One-shot by nature — the
        /// server rejects a replayed code — so it is cleared after a successful
        /// sign-in rather than kept for the next unlock.
        var twoFactorToken: String?
        var deviceIdentifier: String = UUID().uuidString
        var deviceName: String = "Zen for iOS"
        var deviceType: Int = 1
        var clientID: String = "browser"

        init(serverURL: URL, email: String) {
            self.serverURL = serverURL
            self.email = email
        }
    }

    // MARK: Identity

    nonisolated let kind: VaultProviderKind = .bitwarden
    /// The host, never the email and never the password — see
    /// `PasswordVaultProvider`'s doc on `serverDescription`.
    nonisolated let serverDescription: String

    // MARK: State

    private var configuration: Configuration
    private let client: BitwardenAPIClient
    private let masterPasswordSource: BitwardenMasterPasswordSource
    private let argon2: Argon2Hashing

    /// The 64-byte account key every cipher is encrypted with. Its presence is
    /// what `isUnlocked` means.
    private var userKey: BitwardenSymmetricKey?
    /// The last decoded vault, keyed for `reveal(_:)`. Holds plaintext
    /// passwords, so `lock()` empties it.
    private var cache: [VaultItemID: VaultLogin] = [:]
    private var folderNames: [String: String] = [:]

    /// How many items the last `allLogins()` could not read. Almost always
    /// organisation-owned ciphers.
    private(set) var skippedItemCount = 0

    // MARK: Init

    init(
        configuration: Configuration,
        masterPassword: @escaping BitwardenMasterPasswordSource,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        argon2: Argon2Hashing = Argon2Unavailable()
    ) throws {
        var clientConfiguration = BitwardenAPIClient.Configuration(
            serverURL: configuration.serverURL)
        clientConfiguration.allowsSelfSignedTLS = configuration.allowsSelfSignedTLS
        clientConfiguration.deviceIdentifier = configuration.deviceIdentifier
        clientConfiguration.deviceName = configuration.deviceName
        clientConfiguration.deviceType = configuration.deviceType
        clientConfiguration.clientID = configuration.clientID

        let client = try BitwardenAPIClient(
            configuration: clientConfiguration,
            sessionConfiguration: sessionConfiguration)

        self.configuration = configuration
        self.client = client
        self.serverDescription = client.host
        self.masterPasswordSource = masterPassword
        self.argon2 = argon2
    }

    /// A source for a password already in hand — the connect sheet's "Test
    /// connection", and tests.
    ///
    /// A free function rather than a second initialiser, and used sparingly:
    /// the captured string lives as long as the provider does, so a provider
    /// built this way cannot really forget the master password on `lock()`.
    nonisolated static func constant(
        _ masterPassword: String
    ) -> BitwardenMasterPasswordSource {
        { masterPassword }
    }

    // MARK: PasswordVaultProvider

    var isUnlocked: Bool { userKey != nil }

    /// Sign in, download the vault, and report what is in it.
    ///
    /// Deliberately the full journey rather than a cheap `GET /alive`: the
    /// failures worth catching on a settings screen are a wrong master
    /// password, an Argon2 account, and a certificate iOS will not trust —
    /// none of which a reachability check would find.
    func verifyConnection() async throws -> [VaultSummary] {
        let key = try await unlockedKey()
        let response = try await client.sync()
        let logins = decodeVault(response, key: key)

        // Bitwarden has no "vaults" in the 1Password sense: there is one
        // personal vault plus organisations we cannot read. So the first
        // summary is the account itself, and the rest are its folders as a
        // breakdown of that same total — not additional collections.
        var summaries: [VaultSummary] = [
            VaultSummary(
                id: response.profile?.id ?? "personal",
                name: response.profile?.email ?? BitwardenCrypto.normalise(
                    email: configuration.email),
                itemCount: logins.count)
        ]
        for (id, name) in folderNames.sorted(by: { $0.value < $1.value }) {
            summaries.append(
                VaultSummary(
                    id: id,
                    name: name,
                    itemCount: logins.filter { $0.vaultName == name }.count))
        }
        return summaries
    }

    func allLogins() async throws -> [VaultLogin] {
        let key = try await unlockedKey()
        return decodeVault(try await client.sync(), key: key)
    }

    /// The cached item, on purpose.
    ///
    /// `/api/sync` already carried this login's password and TOTP seed and we
    /// already decrypted them, so a request here would buy nothing and cost
    /// something: latency in front of a fill, and a per-item access pattern in
    /// the server's logs that says which site the user just signed in to. If
    /// the cache is cold — first call after `lock()` — one bulk sync fills it.
    func reveal(_ id: VaultItemID) async throws -> VaultLogin {
        if let cached = cache[id] { return cached }
        _ = try await allLogins()
        guard let login = cache[id] else {
            throw VaultError.notFound("this login is no longer in the vault")
        }
        return login
    }

    func createLogin(_ draft: VaultLoginDraft) async throws -> VaultLogin {
        let key = try await unlockedKey()
        let cipher = try await client.createCipher(try makeRequest(draft, key: key))
        return try store(cipher, key: key, fallingBackTo: draft)
    }

    func updateLogin(_ id: VaultItemID, with draft: VaultLoginDraft) async throws -> VaultLogin {
        let key = try await unlockedKey()
        // Keep the folder the item already lives in: a save prompt that
        // silently moved a login out of "Banking" would be a small betrayal.
        let folderId = cache[id].flatMap { existing in
            folderNames.first { $0.value == existing.vaultName }?.key
        }
        let cipher = try await client.updateCipher(
            id: id.rawValue, try makeRequest(draft, key: key, folderId: folderId))
        return try store(cipher, key: key, fallingBackTo: draft, id: id)
    }

    /// Forget the derived key, the decrypted vault, and the session token.
    ///
    /// Not a logout: the configuration stays, so the next call can sign in
    /// again with whatever the master-password source provides.
    func lock() async {
        userKey = nil
        cache.removeAll()
        folderNames.removeAll()
        skippedItemCount = 0
        await client.clearSession()
    }

    // MARK: Unlocking

    private func unlockedKey() async throws -> BitwardenSymmetricKey {
        if let userKey { return userKey }

        let password = try await masterPasswordSource()
        guard !password.isEmpty else { throw VaultError.locked }

        // Ask before deriving: the KDF is a property of the *account*, not of
        // the server, and an account created years ago may still be on 100 000
        // iterations while the server's default is 600 000.
        let kdf = try await client.prelogin(email: configuration.email).kdfDescriptor()
        let masterKey = try BitwardenCrypto.masterKey(
            password: password,
            email: configuration.email,
            kdf: kdf,
            argon2: argon2)
        let hash = try BitwardenCrypto.masterPasswordHash(
            masterKey: masterKey, password: password)

        let token = try await client.login(
            email: configuration.email,
            masterPasswordHash: hash,
            totp: configuration.twoFactorToken)
        // A second-factor code is single-use; replaying it on the next unlock
        // would fail in a way that reads like a wrong password.
        configuration.twoFactorToken = nil

        var wrapped = token.key
        if wrapped == nil || wrapped?.isEmpty == true {
            // Older self-hosted servers omit `Key` from the token response and
            // only carry it on the profile.
            wrapped = try await client.sync().profile?.key
        }
        guard let wrapped, !wrapped.isEmpty else {
            throw VaultError.decoding(
                "the server did not return this account's encrypted key, so the vault cannot "
                    + "be opened")
        }

        let key = try BitwardenCrypto.unwrapUserKey(
            protectedKey: wrapped,
            stretchedMasterKey: BitwardenCrypto.stretch(masterKey: masterKey))
        userKey = key
        return key
    }

    // MARK: Decoding

    /// Turn a sync response into logins, and remember them for `reveal(_:)`.
    ///
    /// Non-throwing on purpose. Every per-item failure is counted rather than
    /// propagated, because the alternative — one organisation cipher taking
    /// down the whole list — is the failure mode that makes people stop
    /// trusting a password manager.
    private func decodeVault(
        _ response: BitwardenSyncResponse,
        key: BitwardenSymmetricKey
    ) -> [VaultLogin] {
        folderNames = [:]
        for folder in response.folders ?? [] {
            guard let id = folder.id, let encrypted = folder.name,
                let name = try? EncString.parse(encrypted).decryptToString(key: key)
            else { continue }
            folderNames[id] = name
        }

        var logins: [VaultLogin] = []
        var skipped = 0
        for cipher in response.ciphers ?? [] {
            guard cipher.kind == .login, !cipher.isDeleted else { continue }
            // Declared, not inferred. An organisation cipher is encrypted with
            // an organisation key we never unwrap, so in production it would
            // also fail its MAC check a moment later — but "we skipped it
            // because the crypto happened to fail" and "we skipped it because
            // we know we cannot read it" are different statements, and only the
            // second one is still true if a server ever hands back an org item
            // we *could* decrypt. Being explicit is also what makes
            // `skippedItemCount` a number worth showing someone.
            guard !cipher.isOrganisationOwned else {
                skipped += 1
                continue
            }
            do {
                logins.append(try decodeLogin(cipher, key: key))
            } catch {
                // Anything else unreadable: a field encrypted under a type we
                // do not support, or a genuinely corrupt item. Counted, never
                // thrown — one bad cipher must not empty the whole list.
                skipped += 1
            }
        }

        skippedItemCount = skipped
        cache = Dictionary(logins.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return logins
    }

    private func decodeLogin(
        _ cipher: BitwardenCipher,
        key: BitwardenSymmetricKey
    ) throws -> VaultLogin {
        guard let id = cipher.id, !id.isEmpty else {
            throw VaultError.decoding("a login arrived without an id")
        }
        guard let encryptedName = cipher.name else {
            throw VaultError.decoding("a login arrived without a name")
        }
        // Decrypting the name first is also the organisation check: an org
        // cipher fails here, before any secret field is looked at.
        let title = try EncString.parse(encryptedName, field: "item name")
            .decryptToString(key: key, field: "item name")

        let login = cipher.login
        let uris = (login?.uris ?? []).compactMap { entry -> VaultURI? in
            guard let encrypted = entry.uri,
                let uri = try? EncString.parse(encrypted).decryptToString(key: key),
                !uri.isEmpty
            else { return nil }
            // `match` is Bitwarden's `UriMatchType` and `VaultURIMatch` shares
            // its raw values deliberately. Null means "the account default",
            // which Bitwarden ships as base-domain matching.
            return VaultURI(uri: uri, match: VaultURIMatch(rawValue: entry.match ?? 0) ?? .domain)
        }

        return VaultLogin(
            id: VaultItemID(id),
            title: title,
            username: try decryptOptional(login?.username, key: key, field: "username"),
            password: try decryptOptional(login?.password, key: key, field: "password"),
            totp: try decryptOptional(login?.totp, key: key, field: "one-time code"),
            uris: uris,
            vaultName: cipher.folderId.flatMap { folderNames[$0] },
            updatedAt: BitwardenDate.parse(cipher.revisionDate)
        )
    }

    private func decryptOptional(
        _ encrypted: String?,
        key: BitwardenSymmetricKey,
        field: String
    ) throws -> String? {
        guard let encrypted, !encrypted.isEmpty else { return nil }
        return try EncString.parse(encrypted, field: field)
            .decryptToString(key: key, field: field)
    }

    // MARK: Writing

    /// Every string on a cipher is an EncString; nothing but the ids, the type
    /// and the flags reaches the server in the clear.
    private func makeRequest(
        _ draft: VaultLoginDraft,
        key: BitwardenSymmetricKey,
        folderId: String? = nil
    ) throws -> BitwardenCipherRequest {
        // Sealed one at a time rather than inline: an empty field is written as
        // a *missing* field, the way Bitwarden's own clients do it, and
        // `AESCBC` cannot encrypt zero bytes anyway.
        var sealedUsername: String?
        if !draft.username.isEmpty {
            sealedUsername = try seal(draft.username, key: key)
        }
        var sealedPassword: String?
        if !draft.password.isEmpty {
            sealedPassword = try seal(draft.password, key: key)
        }
        var sealedTOTP: String?
        if let totp = draft.totp, !totp.isEmpty {
            sealedTOTP = try seal(totp, key: key)
        }
        var uris: [BitwardenCipherRequest.Login.URI] = []
        if !draft.uri.isEmpty {
            uris.append(
                BitwardenCipherRequest.Login.URI(
                    uri: try seal(draft.uri, key: key),
                    // nil, not 0: "use whatever the account's default match is"
                    // is a different statement from "match by domain", and
                    // writing 0 would pin a choice the user never made.
                    match: nil))
        }

        var request = BitwardenCipherRequest(name: try seal(draft.title, key: key))
        request.folderId = folderId
        request.login = BitwardenCipherRequest.Login(
            username: sealedUsername,
            password: sealedPassword,
            totp: sealedTOTP,
            uris: uris
        )
        return request
    }

    private func seal(_ value: String, key: BitwardenSymmetricKey) throws -> String {
        try EncString.encrypt(value, key: key).description
    }

    /// Fold the server's echo of a written cipher back into the cache.
    ///
    /// The server is the authority on the id and the revision date, so its
    /// answer is preferred. But a server that echoes something we cannot
    /// decode must not turn a *successful save* into an error the user reads
    /// as "it did not save" — so the draft is the fallback.
    private func store(
        _ cipher: BitwardenCipher,
        key: BitwardenSymmetricKey,
        fallingBackTo draft: VaultLoginDraft,
        id: VaultItemID? = nil
    ) throws -> VaultLogin {
        if let decoded = try? decodeLogin(cipher, key: key) {
            cache[decoded.id] = decoded
            return decoded
        }
        guard let resolved = id ?? cipher.id.map({ VaultItemID($0) }) else {
            throw VaultError.decoding("the server saved the login but did not say under what id")
        }
        let login = VaultLogin(
            id: resolved,
            title: draft.title,
            username: draft.username.isEmpty ? nil : draft.username,
            password: draft.password,
            totp: draft.totp,
            uris: draft.uri.isEmpty ? [] : [VaultURI(uri: draft.uri)],
            updatedAt: BitwardenDate.parse(cipher.revisionDate) ?? Date()
        )
        cache[resolved] = login
        return login
    }
}
