//  OnePasswordVaultProvider.swift
//  `PasswordVaultProvider` for 1Password Connect (#008AD).
//
//  ## Why `allLogins()` and `reveal(_:)` really are two different requests
//
//  `PasswordVaultProvider` was written with a specific asymmetry in mind:
//  Bitwarden's bulk sync hands back every cipher, decrypted client-side, in
//  one list call — so its `allLogins()` can populate `password` for
//  everything at once. Connect cannot do that even if it wanted to: its list
//  endpoint returns summaries with no `fields` at all (see
//  `OnePasswordConnectClient`'s header), so there is no bulk secret to
//  return. `allLogins()` here therefore returns logins with `username` and
//  `password` both `nil` — not "not fetched yet" in some lazy sense, but
//  genuinely absent from the response Connect sent — and `reveal(_:)` does
//  the one-item GET that is the *only* Connect request that ever returns a
//  password. `VaultIndex` (`hasCachedSecret`) already assumes a provider can
//  behave this way; this is the provider that actually does.
//
//  ## The vault a write goes to
//
//  `VaultConfiguration` (`VaultCredentialStore.swift`) has no "which vault"
//  field, deliberately — a Connect access token is normally already scoped to
//  a single vault at mint time (`op connect token create --vault …`), so
//  asking the user to pick one again in Zen's settings would just be asking
//  them to repeat themselves. `listVaults()` can still return more than one
//  when a token *does* span several (Connect allows it); `createLogin` and
//  `updateLogin`-onto-a-new-item then target the lowest vault id,
//  deterministically, and that is a real limitation named here rather than
//  hidden: a multi-vault token has no way, through this provider, to choose
//  which vault a *new* item lands in. `updateLogin` on an *existing* item has
//  no such ambiguity — it always writes back to the vault the item already
//  lives in.
//
//  ## Packing the vault id into `VaultItemID`
//
//  Connect's item routes are nested under a vault
//  (`/v1/vaults/{vaultId}/items/{itemId}`), but `VaultItemID` is a single
//  opaque string with no vault slot — the protocol reads naturally for
//  Bitwarden, where an item id is unique across the whole account. Connect
//  item ids are only unique *within* a vault, so the id this provider hands
//  upward packs both: `"<vaultId>/<itemId>"`. 1Password ids are 26-character
//  base32 ULIDs and never contain a slash, so splitting on the first one is
//  unambiguous. Nothing above `PasswordVaultProvider` needs to know this — it
//  is exactly the kind of provider-private detail `VaultItemID`'s doc comment
//  says nothing above this layer should care about.

import Foundation

actor OnePasswordVaultProvider: PasswordVaultProvider {

    nonisolated let kind: VaultProviderKind = .onePasswordConnect
    nonisolated let serverDescription: String

    private let client: OnePasswordConnectClient

    /// 1Password Connect has no separate "unlock" step of its own — the
    /// bearer token either works or it does not, there is no local key
    /// derivation to hold or drop the way Bitwarden's master password has.
    /// Always `true` so the panel does not show an unlock prompt for a
    /// concept Connect doesn't have; `verifyConnection()` is what actually
    /// proves the token works.
    let isUnlocked: Bool = true

    /// - Parameters:
    ///   - baseURL: The Connect server, e.g. `https://connect.lan:8080`.
    ///   - token: The Connect access token.
    ///   - allowsSelfSignedTLS: See `OnePasswordConnectTLSDelegate`.
    init(
        baseURL: URL,
        token: String,
        allowsSelfSignedTLS: Bool = false,
        urlSessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.client = OnePasswordConnectClient(
            baseURL: baseURL, token: token, allowsSelfSignedTLS: allowsSelfSignedTLS,
            sessionConfiguration: urlSessionConfiguration)
        // The host, never the token — see `PasswordVaultProvider`'s doc on
        // `serverDescription`.
        self.serverDescription = baseURL.host ?? baseURL.absoluteString
    }

    // MARK: PasswordVaultProvider

    func verifyConnection() async throws -> [VaultSummary] {
        try await client.listVaults().map(Self.summary(from:))
    }

    func allLogins() async throws -> [VaultLogin] {
        var logins: [VaultLogin] = []
        for vault in try await client.listVaults() {
            let summaries = try await client.listItemSummaries(vaultID: vault.id)
            let loginCategory = OnePasswordConnect.Category.login
            for summary in summaries where summary.category == loginCategory {
                logins.append(Self.login(from: summary, vaultName: vault.name))
            }
        }
        return logins
    }

    func reveal(_ id: VaultItemID) async throws -> VaultLogin {
        let (vaultID, itemID) = try Self.split(id)
        let item = try await client.item(vaultID: vaultID, itemID: itemID)
        return Self.login(from: item)
    }

    func createLogin(_ draft: VaultLoginDraft) async throws -> VaultLogin {
        let vaultID = try await defaultVaultID()
        let body = Self.write(from: draft, id: nil, vaultID: vaultID)
        let item = try await client.createItem(vaultID: vaultID, body: body)
        return Self.login(from: item)
    }

    func updateLogin(_ id: VaultItemID, with draft: VaultLoginDraft) async throws
        -> VaultLogin
    {
        let (vaultID, itemID) = try Self.split(id)
        let body = Self.write(from: draft, id: itemID, vaultID: vaultID)
        let item = try await client.updateItem(vaultID: vaultID, itemID: itemID, body: body)
        return Self.login(from: item)
    }

    /// No-op: see the `isUnlocked` comment above — there is no local key
    /// material for this provider to drop. Present so `PasswordVaultService`
    /// (`forgetVault`) can call `lock()` on whichever provider is configured
    /// without special-casing Connect.
    func lock() async {}

    // MARK: Vault selection

    /// The vault a *new* item goes into — see the file header. Resolved on
    /// every call rather than cached at `init`, because caching it would mean
    /// a vault created or removed from the token's scope after this provider
    /// was constructed never gets picked up.
    private func defaultVaultID() async throws -> String {
        let vaults = try await client.listVaults()
        guard let first = vaults.min(by: { $0.id < $1.id }) else {
            throw VaultError.notFound("No vault is visible to this Connect token.")
        }
        return first.id
    }

    // MARK: VaultItemID packing

    private static func composite(vaultID: String, itemID: String) -> VaultItemID {
        VaultItemID("\(vaultID)/\(itemID)")
    }

    private static func split(_ id: VaultItemID) throws -> (vaultID: String, itemID: String) {
        let parts = id.rawValue.split(
            separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw VaultError.notFound("\(id) is not a 1Password Connect item id.")
        }
        return (String(parts[0]), String(parts[1]))
    }

    // MARK: Mapping — wire model to `PasswordVaultProvider`'s model

    private static func summary(from vault: OnePasswordConnect.Vault) -> VaultSummary {
        VaultSummary(id: vault.id, name: vault.name, itemCount: vault.items)
    }

    /// From a list-endpoint summary: no `fields`, so `username`/`password`/
    /// `totp` are `nil` on principle, not by omission — see the file header.
    private static func login(from summary: OnePasswordConnect.ItemSummary, vaultName: String)
        -> VaultLogin
    {
        VaultLogin(
            id: composite(vaultID: summary.vault.id, itemID: summary.id),
            title: summary.title,
            username: nil,
            password: nil,
            totp: nil,
            uris: uris(from: summary.urls),
            vaultName: vaultName,
            updatedAt: summary.updatedAt)
    }

    /// From the per-item detail endpoint: `fields` is where the secrets are,
    /// keyed by `purpose` for the credential pair and by `type == "OTP"` for
    /// the second factor, because a TOTP field's `purpose` is not a reserved
    /// value the way `USERNAME`/`PASSWORD` are.
    ///
    /// `vaultName` is left `nil` here on purpose: the detail endpoint's
    /// `vault` object carries only an id, never the vault's display name
    /// (unlike the vault list, which has both). The panel already has the
    /// name from the `allLogins()` entry this reveal is completing, so the
    /// gap costs nothing — recorded here rather than papered over with an
    /// extra `listVaults()` call this method has no other reason to make.
    private static func login(from item: OnePasswordConnect.Item) -> VaultLogin {
        var username: String?
        var password: String?
        var totp: String?
        for field in item.fields ?? [] {
            if field.type == OnePasswordConnect.FieldType.otp {
                totp = field.value
                continue
            }
            switch field.purpose {
            case OnePasswordConnect.FieldPurpose.username: username = field.value
            case OnePasswordConnect.FieldPurpose.password: password = field.value
            default: break
            }
        }
        return VaultLogin(
            id: composite(vaultID: item.vault.id, itemID: item.id),
            title: item.title,
            username: username,
            password: password,
            totp: totp,
            uris: uris(from: item.urls),
            vaultName: nil,
            updatedAt: item.updatedAt)
    }

    /// 1Password has no per-URI match-type concept — every `urls[]` entry is
    /// just a label and an `href`, there being no Connect equivalent of
    /// Bitwarden's `UriMatchType`. `.domain` is `VaultURI`'s own documented
    /// default and the one that matches how people actually expect a stored
    /// site to behave (`accounts.example.com` fills on `example.com`), so it
    /// is used here rather than inventing a Connect-specific default that
    /// would just be `.domain` under another name.
    private static func uris(from entries: [OnePasswordConnect.URLEntry]?) -> [VaultURI] {
        (entries ?? []).map { VaultURI(uri: $0.href, match: .domain) }
    }

    private static func write(from draft: VaultLoginDraft, id: String?, vaultID: String)
        -> OnePasswordConnect.ItemWrite
    {
        var fields: [OnePasswordConnect.Field] = [
            OnePasswordConnect.Field(
                id: "username", type: OnePasswordConnect.FieldType.string,
                purpose: OnePasswordConnect.FieldPurpose.username, label: "username",
                value: draft.username),
            OnePasswordConnect.Field(
                id: "password", type: OnePasswordConnect.FieldType.concealed,
                purpose: OnePasswordConnect.FieldPurpose.password, label: "password",
                value: draft.password),
        ]
        if let totp = draft.totp, !totp.isEmpty {
            // No reserved `purpose` for a one-time password — `type == "OTP"`
            // is what identifies it on the way back in, so `purpose` is left
            // empty on the way out, matching what Connect items created
            // through 1Password's own apps look like on the wire.
            fields.append(
                OnePasswordConnect.Field(
                    id: "totp", type: OnePasswordConnect.FieldType.otp, purpose: "",
                    label: "one-time password", value: totp))
        }
        let trimmedURI = draft.uri.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls: [OnePasswordConnect.URLEntry] =
            trimmedURI.isEmpty
            ? []
            : [OnePasswordConnect.URLEntry(label: "website", primary: true, href: trimmedURI)]
        return OnePasswordConnect.ItemWrite(
            id: id,
            vault: OnePasswordConnect.VaultReference(id: vaultID),
            title: draft.title,
            category: OnePasswordConnect.Category.login,
            urls: urls,
            fields: fields)
    }
}
