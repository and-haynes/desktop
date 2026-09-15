//  OnePasswordConnectClient.swift
//  The HTTP/JSON layer for 1Password Connect's v1 API (#008AD).
//
//  Connect is a server someone runs themselves — in the homelab's case, a
//  container next to Vaultwarden — that fronts a 1Password account with a
//  bearer-token API. It is not `HTTPTransport`/`URLSessionTransport` from
//  `Sources/Sync`: that seam exists so Sync's Hawk-signed, backoff-aware
//  requests can be driven by an in-memory mock server, and Connect has none of
//  that shape. What Connect needs instead — a per-host self-signed-certificate
//  opt-in, driven by a `URLSessionDelegate` — is exactly the thing
//  `URLSessionTransport` has no seam for, so this is its own small client
//  rather than a bent-to-fit reuse of Sync's.
//
//  ## The shape that matters: summaries carry no fields
//
//  `GET /v1/vaults/{vaultId}/items` returns **summaries**: title, category,
//  urls, tags — never a field, so never a username or password. Only
//  `GET /v1/vaults/{vaultId}/items/{itemId}` — one request per item — returns
//  `fields`, which is where the username, password and TOTP secret live.
//  Bitwarden's bulk sync has no such split; it hands over ciphers, encrypted
//  but complete, in one list call. That difference is not incidental to this
//  file, it is the reason `OnePasswordVaultProvider` has a two-phase
//  `allLogins()` / `reveal(_:)` split at all — see the comment there.
//
//  ## What this file does not do
//
//  It does not decide *which* vault a write goes to, and it does not cache
//  anything — both are `OnePasswordVaultProvider`'s job. This file is only
//  "turn a Connect path into JSON and JSON into a Connect path", so that the
//  request/response shape can be tested (`OnePasswordConnectTests`) without
//  dragging in matching, indexing or the actor's own state.

import Foundation

// MARK: - Wire model

/// Types that mirror the Connect API's JSON exactly, namespaced so
/// `OnePasswordVaultProvider` can say `OnePasswordConnect.Item` without it
/// reading as some general "Item" belonging to the whole module.
enum OnePasswordConnect {

    /// Category values Connect actually uses. Only `LOGIN` is read or
    /// written by this feature — password-manager items of other categories
    /// (secure notes, credit cards…) are filtered out in
    /// `OnePasswordVaultProvider.allLogins()`, not here, because "what counts
    /// as a login" is provider policy, not wire shape.
    enum Category {
        static let login = "LOGIN"
    }

    /// `fields[].purpose` values that identify a credential. Everything else
    /// (`"NOTES"`, `""`, custom section fields) is carried nowhere — the
    /// panel only understands username/password/TOTP.
    enum FieldPurpose {
        static let username = "USERNAME"
        static let password = "PASSWORD"
    }

    /// `fields[].type` values this file cares about. `CONCEALED` is Connect's
    /// name for a masked text field (passwords); `OTP` is the one whose
    /// `value` is the one-time-password material rather than plain text.
    enum FieldType {
        static let string = "STRING"
        static let concealed = "CONCEALED"
        static let otp = "OTP"
    }

    struct Vault: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let attributeVersion: Int?
        let contentVersion: Int?
        let items: Int?
        let type: String?
        let createdAt: Date?
        let updatedAt: Date?
    }

    /// The `{id}` Connect nests almost everything else under — a vault
    /// reference on an item, never a full vault object.
    struct VaultReference: Codable, Equatable, Sendable {
        let id: String
    }

    struct URLEntry: Codable, Equatable, Sendable {
        let label: String?
        let primary: Bool?
        let href: String

        init(label: String?, primary: Bool?, href: String) {
            self.label = label
            self.primary = primary
            self.href = href
        }
    }

    /// What `GET /v1/vaults/{vaultId}/items` returns per item. Deliberately
    /// has no `fields` property — decoding would silently succeed with `nil`
    /// even if the server changed its mind and started sending them, and
    /// that is the wrong failure mode for a security boundary this explicit.
    /// If Connect ever does start returning fields on the list endpoint, the
    /// fix belongs here as a new, obviously-different type — not as an
    /// optional bolted onto this one.
    struct ItemSummary: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let vault: VaultReference
        let category: String
        let urls: [URLEntry]?
        let tags: [String]?
        let version: Int?
        let createdAt: Date?
        let updatedAt: Date?
    }

    struct SectionReference: Codable, Equatable, Sendable {
        let id: String
    }

    struct Section: Codable, Equatable, Sendable {
        let id: String
        let label: String?
    }

    struct Field: Codable, Equatable, Sendable {
        let id: String?
        let type: String?
        let purpose: String?
        let label: String?
        let value: String?
        let section: SectionReference?

        init(
            id: String?, type: String?, purpose: String?, label: String?, value: String?,
            section: SectionReference? = nil
        ) {
            self.id = id
            self.type = type
            self.purpose = purpose
            self.label = label
            self.value = value
            self.section = section
        }
    }

    /// `GET /v1/vaults/{vaultId}/items/{itemId}` — everything `ItemSummary`
    /// has, plus the `fields` that actually carry the secret.
    struct Item: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let vault: VaultReference
        let category: String
        let urls: [URLEntry]?
        let tags: [String]?
        let version: Int?
        let createdAt: Date?
        let updatedAt: Date?
        let fields: [Field]?
        let sections: [Section]?
    }

    /// The body of a create (`POST`) or replace (`PUT`). `id` is `nil` for a
    /// create — the server assigns one — and set for an update, where Connect
    /// expects the body's id to agree with the path's.
    ///
    /// `encode(to:)` is written out rather than synthesized so that a create
    /// body omits the `id` key entirely instead of sending `"id": null` —
    /// the difference between "no opinion" and "explicitly no id", which for
    /// a REST API that assigns ids server-side is worth being precise about.
    struct ItemWrite: Codable, Equatable, Sendable {
        let id: String?
        let vault: VaultReference
        let title: String
        let category: String
        let urls: [URLEntry]
        let fields: [Field]

        init(
            id: String?, vault: VaultReference, title: String, category: String,
            urls: [URLEntry], fields: [Field]
        ) {
            self.id = id
            self.vault = vault
            self.title = title
            self.category = category
            self.urls = urls
            self.fields = fields
        }

        enum CodingKeys: String, CodingKey {
            case id, vault, title, category, urls, fields
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(vault, forKey: .vault)
            try container.encode(title, forKey: .title)
            try container.encode(category, forKey: .category)
            try container.encode(urls, forKey: .urls)
            try container.encode(fields, forKey: .fields)
        }
    }

    /// Connect's error body, when it sends one: `{"status": 404, "message":
    /// "..."}`. Not every non-2xx necessarily has this shape (a reverse proxy
    /// in front of Connect can return its own HTML error page), which is why
    /// decoding it is a best-effort fallback, not something the caller can
    /// rely on.
    struct ErrorBody: Codable, Equatable, Sendable {
        let status: Int?
        let message: String?
    }
}

// MARK: - TLS delegate

/// Accepts a self-signed certificate — but only for the exact host the
/// provider was configured with, never as a blanket "trust everything"
/// switch on the session.
///
/// What this trades away: for `allowedHost` specifically, an on-path or
/// DNS-spoofing attacker who can present *any* certificate is no longer
/// detectable, because the delegate is being told "trust whatever is
/// presented here" rather than "trust a certificate this device's CA store
/// vouches for". On a LAN Connect box with a certificate nobody but its
/// owner ever issued, that is a reasonable trade — the attacker already has
/// to be on the LAN to reach it at all, self-signed TLS is still better than
/// no TLS, and the alternative (asking a homelab owner to run a private CA
/// just to talk to their own server) is a worse trade in practice. It would
/// be a bad trade for anything reachable over the public internet, which is
/// exactly why this is opt-in per provider (`allowsSelfSignedTLS`) rather
/// than a session-wide default, and why it checks the host on every
/// challenge instead of only at construction time.
final class OnePasswordConnectTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowedHost: String

    init(allowedHost: String) {
        self.allowedHost = allowedHost
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) ->
            Void
    ) {
        let space = challenge.protectionSpace
        guard
            space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            space.host == allowedHost,
            let trust = space.serverTrust
        else {
            // Any other host, or any other kind of challenge (client
            // certificate, HTTP auth): fall back to the platform's normal
            // handling rather than silently failing the request.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - Client

/// Turns Connect's REST paths into typed requests and responses. Holds a
/// bearer token and nothing else stateful — no cache, no notion of "which
/// vault", both of which belong one layer up in `OnePasswordVaultProvider`.
struct OnePasswordConnectClient: Sendable {

    let baseURL: URL
    private let token: String
    private let session: URLSession

    /// - Parameters:
    ///   - token: The Connect access token. Never logged, never placed in an
    ///     error message — `VaultError` cases below only ever carry a status
    ///     code and the server's own message text.
    ///   - allowsSelfSignedTLS: See `OnePasswordConnectTLSDelegate`.
    ///   - sessionConfiguration: Overridable so tests can register a mock
    ///     `URLProtocol` on an isolated configuration rather than touching
    ///     `.default`/`.shared`, which every other test in the process also
    ///     uses.
    init(
        baseURL: URL,
        token: String,
        allowsSelfSignedTLS: Bool = false,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.baseURL = baseURL
        self.token = token
        if allowsSelfSignedTLS, let host = baseURL.host {
            let delegate = OnePasswordConnectTLSDelegate(allowedHost: host)
            self.session = URLSession(
                configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        } else {
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    // MARK: Requests

    func listVaults() async throws -> [OnePasswordConnect.Vault] {
        try await get("/v1/vaults")
    }

    /// Item summaries for one vault — secrets absent, see the file header.
    func listItemSummaries(vaultID: String) async throws -> [OnePasswordConnect.ItemSummary] {
        try await get("/v1/vaults/\(pathEscape(vaultID))/items")
    }

    /// The full item, secrets included.
    func item(vaultID: String, itemID: String) async throws -> OnePasswordConnect.Item {
        try await get("/v1/vaults/\(pathEscape(vaultID))/items/\(pathEscape(itemID))")
    }

    func createItem(vaultID: String, body: OnePasswordConnect.ItemWrite) async throws
        -> OnePasswordConnect.Item
    {
        try await send(
            method: "POST", path: "/v1/vaults/\(pathEscape(vaultID))/items", body: body)
    }

    func updateItem(vaultID: String, itemID: String, body: OnePasswordConnect.ItemWrite)
        async throws -> OnePasswordConnect.Item
    {
        try await send(
            method: "PUT",
            path: "/v1/vaults/\(pathEscape(vaultID))/items/\(pathEscape(itemID))", body: body)
    }

    // MARK: Plumbing

    private func pathEscape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    private func url(_ path: String) throws -> URL {
        guard let resolved = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw VaultError.network("could not build a request URL for \(path)")
        }
        return resolved
    }

    private func authorizedRequest(method: String, path: String) throws -> URLRequest {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        let request = try authorizedRequest(method: "GET", path: path)
        let data = try await perform(request)
        return try decode(data)
    }

    private func send<Body: Encodable, Response: Decodable>(
        method: String, path: String, body: Body
    ) async throws -> Response {
        var request = try authorizedRequest(method: method, path: path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw VaultError.decoding("could not encode the request body: \(error)")
        }
        let data = try await perform(request)
        return try decode(data)
    }

    /// Runs the request and returns the body of a 2xx response, or throws.
    /// This is the one place transport failures and non-2xx statuses are
    /// turned into `VaultError`, so every call site above gets the same
    /// mapping for free.
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw VaultError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw VaultError.network("the server did not answer over HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Best-effort: Connect's own errors are `{status, message}`, but
            // a reverse proxy in front of it can return anything (HTML,
            // plain text, nothing), so a decode failure here falls back to
            // the response's raw text rather than losing the status code
            // entirely.
            if
                let body = try? Self.decoder.decode(
                    OnePasswordConnect.ErrorBody.self, from: data),
                let message = body.message, !message.isEmpty
            {
                throw VaultError.server(status: http.statusCode, message: message)
            }
            let fallback = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw VaultError.server(
                status: http.statusCode,
                message: (fallback?.isEmpty == false ? fallback! : "no further detail"))
        }
        return data
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw VaultError.decoding("\(error)")
        }
    }

    // MARK: Coding

    /// Plain ISO-8601, no fractional seconds — matches every other date
    /// strategy in this module (`VaultIndex`, `JSONFileStore`) and is what
    /// Connect's own `createdAt`/`updatedAt` fields use.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
