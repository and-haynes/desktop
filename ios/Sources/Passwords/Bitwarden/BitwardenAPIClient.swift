//  BitwardenAPIClient.swift
//  The REST half of the Bitwarden / Vaultwarden vault: endpoints, wire models,
//  the OAuth password grant, and `/api/sync` (#008AD).
//
//  Ported from Ghostty's vault sync, which talks to the same homelab
//  Vaultwarden. Two shapes here look over-engineered until you meet the
//  server, so they are explained rather than tidied away:
//
//  * **Casing.** Bitwarden's JSON is not consistently cased and never has
//    been. The OAuth endpoints answer in `snake_case` (`access_token`), the
//    vault endpoints answered in `PascalCase` for years and in `camelCase`
//    today, and a *single response* mixes both (`access_token` beside `Key`).
//    Rather than three `CodingKeys` variants per model, every incoming key is
//    normalised to camelCase and decoded once.
//
//  * **Where `/identity` and `/api` live.** Self-hosted Bitwarden and
//    Vaultwarden put both behind one origin as `/identity` and `/api`; that is
//    the default here. Bitwarden's own cloud splits them across
//    `identity.bitwarden.com` and `api.bitwarden.com`. And a reverse proxy can
//    perfectly well serve the two services at the *root* of their own
//    hostnames — so a 404 on the first request demotes this client to root
//    paths for the rest of the session rather than telling the user their
//    server is broken.
//
//  Unlike Ghostty this has no `BitwardenTransport` protocol. Zen already owns
//  the name `URLSessionTransport` (the Firefox Sync stack), and a second
//  transport seam alongside it would invite exactly the confusion that name
//  collision implies. Instead the client takes a `URLSessionConfiguration`,
//  which is all a test needs: `BitwardenProviderTests` registers a
//  `URLProtocol` on one and no request leaves the machine.

import Foundation

// MARK: - TLS

/// Accepts an otherwise-untrusted server certificate for **one** host.
///
/// The homelab's `vault.lan` is signed by a private CA that iOS has no reason
/// to trust, and a vault you cannot reach at all is a vault nobody will use.
/// But this is exactly the switch that turns TLS into decoration, so be plain
/// about what it costs: with it on, anything that can answer for that hostname
/// — a poisoned DNS answer, a hostile Wi-Fi network — can read the master
/// password hash and every cipher in the account. Hence:
///
/// * It is **off by default** and must be turned on per connection.
/// * It is scoped to the single configured host. Every other host, including
///   any redirect target, goes through normal validation.
/// * It should be surfaced in Settings as a user-visible choice, not a build
///   flag, because the person accepting the risk should be the person who
///   knows whether the server is theirs.
///
/// The properly boring alternative — and what should happen eventually — is
/// installing the homelab CA as a trusted root profile on the device, after
/// which this flag stays off. Pinning the CA's public key here would be better
/// still; it is not done because the CA is not shipped with the app.
/// `@unchecked Sendable`: immutable after `init`, and `URLSession` retains it
/// across whatever queue a challenge arrives on.
final class BitwardenTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let host: String

    init(host: String) {
        self.host = host
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
            challenge.protectionSpace.host == host,
            let trust = challenge.protectionSpace.serverTrust
        else {
            // Anything that is not "the server I was told to expect presenting
            // a certificate" gets the system's own answer.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - Session

/// Owns the `URLSession` the client talks through.
///
/// A class rather than a stored property on the actor, for one specific
/// reason: `URLSession` retains its delegate until `invalidateAndCancel()`, so
/// the self-signed-TLS path leaks a session and a delegate unless something
/// tears it down — and the natural place for that, an actor's `deinit`, is a
/// context with rules of its own about touching non-`Sendable` state. A plain
/// reference type with a plain `deinit` sidesteps the question.
final class BitwardenHTTPSession {
    private let session: URLSession
    /// Held so the delegate outlives the requests that need it.
    private let tlsDelegate: BitwardenTLSDelegate?

    /// - Parameters:
    ///   - configuration: `.ephemeral` in production. A `/api/sync` response
    ///     contains every encrypted secret the account owns, and a URL cache
    ///     file on disk is not a place to leave them, even encrypted.
    ///   - selfSignedHost: when non-nil, and only for this exact host, an
    ///     untrusted server certificate is accepted. See `BitwardenTLSDelegate`.
    init(configuration: URLSessionConfiguration, selfSignedHost: String?) {
        // `URLSessionConfiguration` is a class, so tightening these settings on
        // the caller's instance would silently reconfigure whatever else they
        // are using it for. Copy first; `copy()` carries `protocolClasses`
        // across, which is what keeps the test stub working.
        let config = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        if let selfSignedHost {
            let delegate = BitwardenTLSDelegate(host: selfSignedHost)
            self.tlsDelegate = delegate
            self.session = URLSession(
                configuration: config, delegate: delegate, delegateQueue: nil)
        } else {
            self.tlsDelegate = nil
            self.session = URLSession(configuration: config)
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

// MARK: - Endpoints

/// Where the identity and API services live for a given server.
struct BitwardenEndpoints: Equatable {
    /// `https://vault.lan/identity` for a self-hosted server.
    let identity: URL
    /// `https://vault.lan/api`.
    let api: URL
    /// The same two services as a proxy that strips the prefix would serve
    /// them. Used only after a 404 proves the prefixed form wrong.
    let rootIdentity: URL
    let rootAPI: URL
    /// True when `identity`/`api` differ from their root forms, i.e. when
    /// falling back is a meaningful thing to try.
    let usesServicePrefixes: Bool
    /// The host TLS exceptions and the account label are scoped to.
    let host: String

    init(serverURL: URL) throws {
        guard let host = serverURL.host, !host.isEmpty else {
            throw VaultError.network(
                "\"\(serverURL.absoluteString)\" has no host. Enter a full URL such as "
                    + "https://vault.lan or https://vault.bitwarden.com."
            )
        }
        guard let scheme = serverURL.scheme?.lowercased(),
            scheme == "https" || scheme == "http"
        else {
            throw VaultError.network("\"\(serverURL.absoluteString)\" is not an http(s) URL.")
        }
        self.host = host

        if host == "bitwarden.com" || host == "vault.bitwarden.com"
            || host == "www.bitwarden.com"
        {
            guard let identity = URL(string: "https://identity.bitwarden.com"),
                let api = URL(string: "https://api.bitwarden.com")
            else {
                throw VaultError.network("Could not build Bitwarden cloud endpoints.")
            }
            self.identity = identity
            self.api = api
            self.rootIdentity = identity
            self.rootAPI = api
            self.usesServicePrefixes = false
        } else {
            // Trailing slashes matter to `appendingPathComponent` only in that
            // they produce "//"; normalise first.
            var base = serverURL
            while base.absoluteString.hasSuffix("/"),
                let trimmed = URL(string: String(base.absoluteString.dropLast()))
            {
                base = trimmed
            }
            self.identity = base.appendingPathComponent("identity")
            self.api = base.appendingPathComponent("api")
            self.rootIdentity = base
            self.rootAPI = base
            self.usesServicePrefixes = true
        }
    }
}

// MARK: - JSON

/// JSON coding shared by every Bitwarden request and response.
enum BitwardenJSON {
    /// Normalise any of Bitwarden's three casings to camelCase. See the file
    /// header for why one response can need all three.
    static func normalisedKey(_ key: String) -> String {
        var joined = key
        if key.contains("_") {
            let parts = key.split(separator: "_", omittingEmptySubsequences: true)
                .map(String.init)
            guard let first = parts.first else { return key }
            joined =
                first
                + parts.dropFirst().map { part -> String in
                    guard let head = part.first else { return part }
                    return head.uppercased() + part.dropFirst()
                }.joined()
        }
        guard let head = joined.first else { return joined }
        return head.lowercased() + joined.dropFirst()
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            BitwardenCodingKey(stringValue: normalisedKey(path[path.count - 1].stringValue))
        }
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Modern Bitwarden and Vaultwarden both accept camelCase request
        // bodies; Vaultwarden matches field names case-insensitively.
        //
        // `withoutEscapingSlashes` because every EncString we send is base64,
        // "/" is one of base64's 64 characters, and Foundation escapes it as
        // "\/" by default. Both are valid JSON and Vaultwarden reads either,
        // but a body that looks like what every other Bitwarden client sends is
        // one fewer thing to rule out when a write is rejected.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

struct BitwardenCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = Int(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - Wire models

struct BitwardenPrelogin: Decodable, Equatable {
    var kdf: Int
    var kdfIterations: Int
    var kdfMemory: Int?
    var kdfParallelism: Int?

    /// Turn the server's three loose integers into the KDF we can act on.
    func kdfDescriptor() throws -> BitwardenKDF {
        switch kdf {
        case 0:
            return .pbkdf2(iterations: kdfIterations)
        case 1:
            // The server sends nulls for these on a PBKDF2 account; on an
            // Argon2 account they are always present. Defaults match
            // Bitwarden's own (3 passes, 64 MiB, 4 lanes) so a server that
            // omits them does not produce a nonsense key.
            return .argon2id(
                iterations: kdfIterations,
                memoryMiB: kdfMemory ?? 64,
                parallelism: kdfParallelism ?? 4
            )
        default:
            throw VaultError.unsupported(
                "This account uses KDF type \(kdf), which Zen does not know. Only PBKDF2 (0) "
                    + "and Argon2id (1) exist today."
            )
        }
    }
}

struct BitwardenTokenResponse: Decodable {
    var accessToken: String
    var expiresIn: Int?
    var refreshToken: String?
    /// The account's protected user key, as an EncString.
    var key: String?
    var privateKey: String?
    var kdf: Int?
    var kdfIterations: Int?
    var kdfMemory: Int?
    var kdfParallelism: Int?
}

/// Every error body Bitwarden and Vaultwarden produce, in one decodable.
///
/// The identity endpoints answer OAuth-shaped (`error`,`error_description`),
/// the API endpoints answer `{"message":…,"validationErrors":…}`, and older
/// builds answer `{"ErrorModel":{"Message":…}}`. Which one you get depends on
/// the endpoint *and* the version, so all three are tried in turn.
struct BitwardenErrorBody: Decodable {
    var error: String?
    var errorDescription: String?
    var message: String?
    var errorModel: ErrorModel?
    /// Modern shape: `{"0": {...}}` keyed by provider number.
    var twoFactorProviders2: [String: IgnoredValue?]?
    /// Legacy shape: `["0"]`.
    var twoFactorProviders: [String]?

    struct ErrorModel: Decodable {
        var message: String?
    }

    /// Anything whose contents we do not care about, only its presence.
    struct IgnoredValue: Decodable {
        init(from decoder: Decoder) throws {}
    }

    var providerIDs: [String] {
        if let twoFactorProviders2, !twoFactorProviders2.isEmpty {
            return twoFactorProviders2.keys.sorted()
        }
        return twoFactorProviders ?? []
    }

    var wantsTwoFactor: Bool {
        !providerIDs.isEmpty
            || (error == "invalid_grant"
                && (errorDescription?.localizedCaseInsensitiveContains("two") ?? false))
    }

    var bestMessage: String? {
        for candidate in [errorModel?.message, message, errorDescription, error] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }
}

struct BitwardenSyncResponse: Decodable {
    struct Profile: Decodable {
        var id: String?
        var email: String?
        var name: String?
        /// The protected user key, same value the token response carries.
        var key: String?
    }

    struct Folder: Decodable {
        var id: String?
        /// An EncString, like every other name in the vault.
        var name: String?
    }

    var profile: Profile?
    var folders: [Folder]?
    var ciphers: [BitwardenCipher]?
}

/// A cipher as the server reports it.
struct BitwardenCipher: Decodable, Equatable {
    /// Bitwarden's `CipherType`. Zen reads exactly one of them.
    enum Kind: Int {
        case login = 1
        case secureNote = 2
        case card = 3
        case identity = 4
        case sshKey = 5
    }

    struct Login: Decodable, Equatable {
        struct URI: Decodable, Equatable {
            /// EncString.
            var uri: String?
            /// Bitwarden's `UriMatchType`, and null for "use the default".
            /// `VaultURIMatch` deliberately shares these raw values.
            var match: Int?
        }

        var username: String?
        var password: String?
        var totp: String?
        var uris: [URI]?
    }

    var id: String?
    var organizationId: String?
    var folderId: String?
    var type: Int
    var name: String?
    var notes: String?
    var favorite: Bool?
    var reprompt: Int?
    var login: Login?
    var revisionDate: String?
    var deletedDate: String?

    var kind: Kind? { Kind(rawValue: type) }
    /// Items in the trash still arrive in `/api/sync`; treat them as gone.
    var isDeleted: Bool { !(deletedDate ?? "").isEmpty }
    /// An organisation's ciphers are encrypted with that organisation's key,
    /// which arrives RSA-wrapped under the account's private key. Zen does not
    /// unwrap org keys, so these are unreadable by construction rather than by
    /// accident — see `BitwardenVaultProvider.decodeLogin`.
    var isOrganisationOwned: Bool { !(organizationId ?? "").isEmpty }
}

/// A cipher as the server wants it written.
///
/// Separate from `BitwardenCipher` because the request shape genuinely differs:
/// `id`, `object` and `revisionDate` are server-owned and rejected or ignored
/// on the way in, and `lastKnownRevisionDate` exists only on the way in — it is
/// the server's optimistic-concurrency check.
struct BitwardenCipherRequest: Encodable {
    struct Login: Encodable {
        struct URI: Encodable {
            var uri: String
            var match: Int? = nil
        }

        var username: String? = nil
        var password: String? = nil
        var totp: String? = nil
        var uris: [URI] = []
    }

    // Every optional carries an explicit `= nil` so the memberwise initialiser
    // offers it as a default: a caller should be able to write
    // `BitwardenCipherRequest(name:)` and mean it.
    var type: Int = BitwardenCipher.Kind.login.rawValue
    var name: String
    var notes: String? = nil
    var folderId: String? = nil
    var organizationId: String? = nil
    var favorite: Bool = false
    var reprompt: Int = 0
    var login: Login? = nil
    var lastKnownRevisionDate: String? = nil
}

// MARK: - Dates

/// Lenient ISO-8601 parsing.
///
/// Bitwarden sends `revisionDate` as `2026-09-14T12:00:00.0000000Z` — seven
/// fractional digits, which `ISO8601DateFormatter` rejects outright. A date
/// that fails to parse must not take a whole sync down with it, so this
/// degrades to nil and the caller carries on.
enum BitwardenDate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = fractional.date(from: text) { return date }
        if let date = whole.date(from: text) { return date }
        // Truncate over-long fractional parts to the three digits the
        // formatter accepts, rather than losing the date entirely.
        if let dot = text.firstIndex(of: "."),
            let zone = text.lastIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }),
            dot < zone
        {
            let fraction = text[text.index(after: dot)..<zone]
            let padded = String((fraction + "000").prefix(3))
            let rebuilt = text[text.startIndex..<dot] + "." + padded + text[zone...]
            return fractional.date(from: String(rebuilt))
        }
        return nil
    }
}

// MARK: - Client

/// Bitwarden / Vaultwarden REST client.
///
/// An `actor` because it owns mutable session state (access token, expiry,
/// refresh token, and which path layout the server turned out to use) that the
/// panel and a foreground refresh can both reach for concurrently, and a token
/// refresh racing itself produces two sessions and one revoked token.
actor BitwardenAPIClient {

    struct Configuration {
        var serverURL: URL
        /// See `BitwardenTLSDelegate`. Default off, deliberately.
        var allowsSelfSignedTLS: Bool = false
        /// Stable per-install id. The server ties sessions and two-step
        /// "remember this device" to it, so it must not change per launch.
        var deviceIdentifier: String = UUID().uuidString
        var deviceName: String = "Zen for iOS"
        /// Bitwarden's `DeviceType`: 1 is iOS.
        var deviceType: Int = 1
        /// Bitwarden's official browser extensions send `browser`, and that is
        /// what Zen is. Vaultwarden does not validate it; upstream Bitwarden
        /// does, so it is not merely cosmetic.
        var clientID: String = "browser"

        init(serverURL: URL) {
            self.serverURL = serverURL
        }
    }

    private enum Service {
        case identity
        case api
    }

    private let configuration: Configuration
    private let endpoints: BitwardenEndpoints
    private let session: BitwardenHTTPSession

    private var accessToken: String?
    private var accessTokenExpiry: Date?
    private var refreshToken: String?
    /// Flipped by the first 404 — see the file header.
    private var usesRootPaths = false

    /// Refresh slightly early; a token that expires mid-flight looks like an
    /// auth failure to the user.
    private let refreshLeeway: TimeInterval = 60

    nonisolated let host: String

    /// - Parameter sessionConfiguration: `.ephemeral` by default because a
    ///   `/api/sync` response contains every encrypted secret the account owns,
    ///   and a URL cache file on disk is not a place to leave them. Tests pass
    ///   a configuration carrying a `URLProtocol` stub.
    init(
        configuration: Configuration,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) throws {
        // Resolved into locals before any `self` assignment: reading back a
        // stored property of a partially-initialised actor from its own
        // nonisolated `init` is an error in Swift 6.
        let endpoints = try BitwardenEndpoints(serverURL: configuration.serverURL)
        let session = BitwardenHTTPSession(
            configuration: sessionConfiguration,
            selfSignedHost: configuration.allowsSelfSignedTLS ? endpoints.host : nil)

        self.configuration = configuration
        self.endpoints = endpoints
        self.host = endpoints.host
        self.session = session
    }

    // MARK: Session

    var hasSession: Bool { accessToken != nil }

    func clearSession() {
        accessToken = nil
        accessTokenExpiry = nil
        refreshToken = nil
    }

    // MARK: Prelogin

    /// Ask the server how this account's master key is derived.
    ///
    /// Unauthenticated by design — the client needs the KDF parameters before
    /// it can produce anything the server would accept.
    func prelogin(email: String) async throws -> BitwardenPrelogin {
        let body = try BitwardenJSON.encoder.encode(
            ["email": BitwardenCrypto.normalise(email: email)])
        let (data, response) = try await perform(
            .identity,
            path: "accounts/prelogin",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        try throwIfError(
            data: data, response: response,
            context: "asking the server how this account's password is hashed")
        return try decode(BitwardenPrelogin.self, from: data, context: "the prelogin response")
    }

    // MARK: Tokens

    /// Password grant. `masterPasswordHash` is the base64 hash, never the
    /// password itself — the server never sees the password.
    func login(
        email: String,
        masterPasswordHash: String,
        totp: String?
    ) async throws -> BitwardenTokenResponse {
        var form: [String: String] = [
            "grant_type": "password",
            "username": BitwardenCrypto.normalise(email: email),
            "password": masterPasswordHash,
            "scope": "api offline_access",
            "client_id": configuration.clientID,
            "deviceType": String(configuration.deviceType),
            "deviceIdentifier": configuration.deviceIdentifier,
            "deviceName": configuration.deviceName,
        ]
        if let totp, !totp.trimmingCharacters(in: .whitespaces).isEmpty {
            form["twoFactorToken"] = totp.trimmingCharacters(in: .whitespaces)
            form["twoFactorProvider"] = "0"  // 0 = authenticator app (TOTP)
            form["twoFactorRemember"] = "0"
        }
        return try await token(form: form)
    }

    @discardableResult
    func refreshAccessToken() async throws -> BitwardenTokenResponse {
        guard let refreshToken else { throw VaultError.locked }
        return try await token(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
        ])
    }

    private func token(form: [String: String]) async throws -> BitwardenTokenResponse {
        // Some deployments key rate limits and device trust off the headers
        // rather than off the form fields, so send both.
        let (data, response) = try await perform(
            .identity,
            path: "connect/token",
            method: "POST",
            body: Data(Self.formURLEncoded(form).utf8),
            contentType: "application/x-www-form-urlencoded",
            headers: [
                "Device-Type": String(configuration.deviceType),
                "Device-Identifier": configuration.deviceIdentifier,
                "Device-Name": configuration.deviceName,
            ]
        )
        try throwIfError(data: data, response: response, context: "signing in")

        let token = try decode(
            BitwardenTokenResponse.self, from: data, context: "the sign-in response")
        accessToken = token.accessToken
        // Absent `expires_in` means "assume short" rather than "assume forever".
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 3600))
        if let newRefresh = token.refreshToken { refreshToken = newRefresh }
        return token
    }

    // MARK: Vault

    func sync() async throws -> BitwardenSyncResponse {
        let (data, response) = try await performAuthorized(
            .api,
            path: "sync",
            method: "GET",
            // Domain equivalence lists are a Bitwarden-autofill feature; Zen
            // does its own matching (`DomainMatching`) and they are a
            // meaningful share of the response size.
            query: [URLQueryItem(name: "excludeDomains", value: "true")]
        )
        try throwIfError(data: data, response: response, context: "downloading the vault")
        return try decode(BitwardenSyncResponse.self, from: data, context: "the vault")
    }

    @discardableResult
    func createCipher(_ cipher: BitwardenCipherRequest) async throws -> BitwardenCipher {
        let (data, response) = try await performAuthorized(
            .api,
            path: "ciphers",
            method: "POST",
            body: try BitwardenJSON.encoder.encode(cipher),
            contentType: "application/json"
        )
        try throwIfError(data: data, response: response, context: "saving a login to the vault")
        return try decode(BitwardenCipher.self, from: data, context: "the saved login")
    }

    @discardableResult
    func updateCipher(id: String, _ cipher: BitwardenCipherRequest) async throws
        -> BitwardenCipher
    {
        let (data, response) = try await performAuthorized(
            .api,
            path: "ciphers/\(id)",
            method: "PUT",
            body: try BitwardenJSON.encoder.encode(cipher),
            contentType: "application/json"
        )
        try throwIfError(data: data, response: response, context: "updating a login in the vault")
        return try decode(BitwardenCipher.self, from: data, context: "the updated login")
    }

    // MARK: Plumbing

    private func performAuthorized(
        _ service: Service,
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        try await refreshIfExpired()
        guard let accessToken else { throw VaultError.locked }

        let result = try await perform(
            service, path: path, method: method, query: query, body: body,
            contentType: contentType,
            headers: ["Authorization": "Bearer \(accessToken)"])
        guard result.response.statusCode == 401, refreshToken != nil else { return result }

        // The server can revoke a token before it expires (password change,
        // session wipe). One refresh-and-retry, then give up rather than loop.
        try await refreshAccessToken()
        guard let renewed = self.accessToken else { throw VaultError.locked }
        return try await perform(
            service, path: path, method: method, query: query, body: body,
            contentType: contentType,
            headers: ["Authorization": "Bearer \(renewed)"])
    }

    private func refreshIfExpired() async throws {
        guard let expiry = accessTokenExpiry else { return }
        guard Date().addingTimeInterval(refreshLeeway) >= expiry else { return }
        guard refreshToken != nil else { return }
        try await refreshAccessToken()
    }

    /// One round trip, with the `/identity`-prefix fallback described in the
    /// file header.
    private func perform(
        _ service: Service,
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let result = try await send(
            try request(
                service, path: path, method: method, query: query, body: body,
                contentType: contentType, headers: headers))
        guard result.response.statusCode == 404, endpoints.usesServicePrefixes, !usesRootPaths
        else { return result }

        // A 404 on the very first call is far more likely to mean "this proxy
        // serves the services at the root" than "the endpoint is gone" — the
        // endpoint names have not changed in years. Demote once, for the rest
        // of the session, and retry.
        usesRootPaths = true
        return try await send(
            try request(
                service, path: path, method: method, query: query, body: body,
                contentType: contentType, headers: headers))
    }

    private func request(
        _ service: Service,
        path: String,
        method: String,
        query: [URLQueryItem],
        body: Data?,
        contentType: String?,
        headers: [String: String]
    ) throws -> URLRequest {
        let base: URL
        switch service {
        case .identity: base = usesRootPaths ? endpoints.rootIdentity : endpoints.identity
        case .api: base = usesRootPaths ? endpoints.rootAPI : endpoints.api
        }

        // `appendingPathComponent` leaves an embedded "/" alone, so
        // "accounts/prelogin" appends as two components, which is what we want.
        var url = base.appendingPathComponent(path)
        if !query.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw VaultError.network("Could not build a request URL for \(url).")
            }
            components.queryItems = query
            guard let withQuery = components.url else {
                throw VaultError.network("Could not build a request URL for \(url).")
            }
            url = withQuery
        }

        var built = URLRequest(url: url)
        built.httpMethod = method
        built.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType {
            built.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            built.setValue(value, forHTTPHeaderField: name)
        }
        built.httpBody = body
        return built
    }

    private func send(_ request: URLRequest) async throws
        -> (data: Data, response: HTTPURLResponse)
    {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw VaultError.decoding("The reply was not an HTTP response.")
            }
            return (data, http)
        } catch let error as VaultError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw VaultError.cancelled
        } catch let error as URLError
            where error.code == .serverCertificateUntrusted
                || error.code == .serverCertificateHasUnknownRoot
                || error.code == .serverCertificateNotYetValid
                || error.code == .serverCertificateHasBadDate
        {
            throw VaultError.network(
                "\(endpoints.host) presented a certificate iOS does not trust. If this is your "
                    + "own server, turn on \"Trust this server's certificate\" for it, or "
                    + "install its certificate authority on this device."
            )
        } catch {
            throw VaultError.network("\(endpoints.host) — \(error.localizedDescription)")
        }
    }

    /// Every non-2xx becomes `VaultError.server(status:message:)`.
    ///
    /// Ghostty split two-factor and CAPTCHA out into their own error type
    /// because its connect sheet can answer them. Zen's `VaultError` — the
    /// contract in `PasswordVaultProvider.swift` — has one server case, so the
    /// distinction survives in the *message* instead: a 2FA prompt that says
    /// "enter the six-digit code" is still actionable, and inventing a case the
    /// protocol does not have would be worse than losing the switch.
    private func throwIfError(data: Data, response: HTTPURLResponse, context: String) throws {
        guard !(200..<300).contains(response.statusCode) else { return }

        let parsed = try? BitwardenJSON.decoder.decode(BitwardenErrorBody.self, from: data)
        var detail: String
        if let parsed, parsed.wantsTwoFactor {
            detail =
                "this account has two-step login enabled. Enter the six-digit code from your "
                + "authenticator app."
        } else if let message = parsed?.bestMessage, !message.isEmpty {
            detail = message
        } else if let body = String(data: data.prefix(400), encoding: .utf8),
            !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            detail = body
        } else {
            detail = "no explanation given"
        }
        if parsed?.bestMessage?.localizedCaseInsensitiveContains("captcha") ?? false {
            detail += " Zen cannot show a CAPTCHA; sign in once in a web browser to clear it."
        }
        throw VaultError.server(
            status: response.statusCode, message: "\(detail) (while \(context))")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws
        -> T
    {
        do {
            return try BitwardenJSON.decoder.decode(type, from: data)
        } catch {
            throw VaultError.decoding("Could not read \(context). \(error.localizedDescription)")
        }
    }

    /// `application/x-www-form-urlencoded`, with `+`, `&` and `=` escaped.
    ///
    /// `.urlQueryAllowed` leaves `+` alone, and a `+` in a form body decodes as
    /// a space — which silently corrupts base64 master password hashes, where
    /// `+` is one of the 64 characters. Roughly half of all sign-ins would fail
    /// with "wrong password", which is the worst possible way to be told.
    static func formURLEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return
            fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}
