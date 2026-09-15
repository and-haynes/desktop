//  PasswordVaultProvider.swift
//  One vocabulary for "a password vault", so the panel does not know or care
//  whether it is talking to 1Password Connect or Vaultwarden (#008AD).
//
//  This is the *experimental* branch's answer to a question `ios` answers
//  differently. On `ios` (#008AB) Zen has no vault at all: iOS Password
//  AutoFill is the whole story, because that is the only route the platform
//  gives a third-party browser into another app's passwords. That remains
//  true and this does not replace it — AutoFill still works, and Settings →
//  Passwords still explains it.
//
//  What this adds is the other direction: a vault Zen talks to *itself*, over
//  the network, because the homelab runs its own. 1Password Connect is a
//  server with a token; Vaultwarden speaks the Bitwarden API. Neither is
//  reachable through AutoFill without the vendor's app installed and chosen as
//  the provider, and neither can offer a TOTP code into a page. So the trade
//  is: more reach, but Zen now handles plaintext secrets, which is exactly why
//  this lives on `experimental` and not on `ios`.
//
//  The seam is deliberately narrow. A provider does four things — prove it can
//  reach the server, list logins, fetch one login's secrets, and write a login
//  back — and everything above it (matching, indexing, filling, TOTP, Face ID)
//  is provider-agnostic and tested once.

import Foundation

// MARK: - Identity

enum VaultProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case onePasswordConnect
    case bitwarden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onePasswordConnect: return "1Password Connect"
        case .bitwarden: return "Bitwarden / Vaultwarden"
        }
    }

    var symbol: String {
        switch self {
        case .onePasswordConnect: return "lock.square.stack"
        case .bitwarden: return "shield.lefthalf.filled"
        }
    }
}

/// A login's identity *within a provider*. Opaque on purpose: 1Password uses
/// ULIDs and Bitwarden uses UUIDs, and nothing above this layer should care.
struct VaultItemID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }

    var description: String { rawValue }
}

// MARK: - Model

/// How a stored URI is meant to be compared against the page you are on.
///
/// Bitwarden's `UriMatchType`, which 1Password has no equivalent of — Connect
/// items get `.domain`, the default that matches the way people expect.
enum VaultURIMatch: Int, Codable, Sendable {
    case domain = 0
    case host = 1
    case startsWith = 2
    case exact = 3
    case regularExpression = 4
    case never = 5
}

struct VaultURI: Equatable, Codable, Sendable {
    var uri: String
    var match: VaultURIMatch

    init(uri: String, match: VaultURIMatch = .domain) {
        self.uri = uri
        self.match = match
    }
}

/// One login, as the panel understands it.
///
/// `password` and `totp` are optional because listing a vault and opening one
/// item are different operations with different costs: 1Password Connect
/// returns items without their fields until asked, and holding every password
/// in memory because the panel is open is not a thing to do casually. A login
/// from `logins(matching:)` may carry nil secrets; one from `reveal(_:)`
/// always carries what the vault has.
struct VaultLogin: Identifiable, Equatable, Sendable {
    let id: VaultItemID
    var title: String
    var username: String?
    var password: String?
    /// Either a bare base32 secret or a full `otpauth://` URI — providers
    /// store both forms and `TOTPGenerator` accepts both.
    var totp: String?
    var uris: [VaultURI]
    /// Which vault/collection it came from, for the subtitle when two vaults
    /// hold the same site.
    var vaultName: String?
    var updatedAt: Date?

    init(
        id: VaultItemID,
        title: String,
        username: String? = nil,
        password: String? = nil,
        totp: String? = nil,
        uris: [VaultURI] = [],
        vaultName: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.password = password
        self.totp = totp
        self.uris = uris
        self.vaultName = vaultName
        self.updatedAt = updatedAt
    }

    var hasSecrets: Bool { password != nil }
}

/// A login on its way *into* a vault, from the save/update prompt.
struct VaultLoginDraft: Equatable, Sendable {
    var title: String
    var username: String
    var password: String
    var uri: String
    var totp: String?

    init(title: String, username: String, password: String, uri: String, totp: String? = nil) {
        self.title = title
        self.username = username
        self.password = password
        self.uri = uri
        self.totp = totp
    }
}

struct VaultSummary: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var itemCount: Int?
}

// MARK: - Errors

/// Provider failures, phrased as things to show someone.
///
/// A vault that will not open is the most frustrating possible failure — the
/// passwords are *right there* — so every case carries a sentence that says
/// what to do, not just what went wrong.
enum VaultError: LocalizedError, Equatable {
    case notConfigured
    case locked
    case network(String)
    case server(status: Int, message: String)
    case crypto(String)
    case decoding(String)
    case unsupported(String)
    case notFound(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No password vault is set up yet. Add one in Settings → Passwords."
        case .locked:
            return "The vault is locked. Unlock it in Settings → Passwords."
        case .network(let detail):
            return "Could not reach the vault server: \(detail)"
        case .server(let status, let message):
            return "The vault server answered \(status): \(message)"
        case .crypto(let detail):
            return detail
        case .decoding(let detail):
            return "The vault server sent something unexpected: \(detail)"
        case .unsupported(let detail):
            return detail
        case .notFound(let detail):
            return "Not in the vault: \(detail)"
        case .cancelled:
            return "Cancelled."
        }
    }
}

// MARK: - The seam

/// What every vault backend must be able to do.
///
/// An actor rather than a protocol on a class: a provider holds an unwrapped
/// key and a session token, the panel and the foreground-refresh both touch it,
/// and "do not race on the key material" is easier to *enforce* than to
/// remember.
protocol PasswordVaultProvider: Actor {
    nonisolated var kind: VaultProviderKind { get }

    /// Human-readable server identity for the settings screen — the host,
    /// typically. Never a token.
    nonisolated var serverDescription: String { get }

    /// True once there is enough in hand to answer `allLogins()` without
    /// another prompt. For Bitwarden that means the user key is unwrapped.
    var isUnlocked: Bool { get }

    /// Prove the server is reachable and the credentials work. Called from the
    /// settings screen's "Test connection", and its error is shown verbatim.
    func verifyConnection() async throws -> [VaultSummary]

    /// Every login the vault will give us, secrets included where the backend
    /// returns them in bulk (Bitwarden does; Connect does not).
    ///
    /// This is what builds the domain index. It is expected to be the
    /// expensive call, and is made on demand and on foreground, not per
    /// keystroke.
    func allLogins() async throws -> [VaultLogin]

    /// One login with its secrets definitely populated.
    func reveal(_ id: VaultItemID) async throws -> VaultLogin

    /// Create a new login. Returns it as stored, so the index can take the
    /// server's id and timestamp rather than guessing.
    func createLogin(_ draft: VaultLoginDraft) async throws -> VaultLogin

    /// Overwrite an existing login's username/password/URI.
    func updateLogin(_ id: VaultItemID, with draft: VaultLoginDraft) async throws -> VaultLogin

    /// Items the last `allLogins()` could not read, rather than could not
    /// find. Bitwarden's organisation-encrypted ciphers are the real case: we
    /// do not unwrap org keys, so those items are skipped — and a vault that
    /// silently shows fewer logins than it holds is a vault nobody trusts. The
    /// settings screen surfaces this.
    var skippedItemCount: Int { get }

    /// Drop cached key material. Not a logout — the stored credentials stay.
    func lock() async
}

extension PasswordVaultProvider {
    /// A provider that can read everything it lists — 1Password Connect, and
    /// every test double — does not have to say so.
    var skippedItemCount: Int { 0 }
}
