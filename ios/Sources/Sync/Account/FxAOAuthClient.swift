//  FxAOAuthClient.swift
//  The Mozilla-account OAuth exchange, with scoped-keys delivery.
//
//  The shape of the flow:
//
//    1. generate an ephemeral P-256 key pair and a PKCE verifier;
//    2. send the public key as `keys_jwk` on the authorization request;
//    3. the user signs in in a system browser sheet and we get a code back;
//    4. exchange the code (with the PKCE verifier) for tokens — the response
//       carries `keys_jwe`, a JWE addressed to the key from step 1;
//    5. decrypt it to get the `oldsync` scoped key: 64 bytes of key material
//       plus the `kid` the token server wants in `X-KeyID`.
//
//  The private key never leaves the process and is thrown away after step 5,
//  so an attacker who records the whole exchange still cannot read the data.

import CryptoKit
import Foundation

/// The endpoints, as discovered from `.well-known/fxa-client-configuration`.
/// Mozilla moves these; the built-in values are a fallback, not the truth.
struct FxAEndpoints: Equatable, Sendable, Codable {
    var contentServer: URL = SyncConfig.defaultContentServer
    var oauthServer: URL = SyncConfig.defaultOAuthServer
    var profileServer: URL = SyncConfig.defaultProfileServer
    var tokenServer: URL = SyncConfig.defaultTokenServer

    static let fallback = FxAEndpoints()

    /// The discovery document's keys, which are not the ones you would guess.
    private enum WellKnown: String {
        case auth = "auth_server_base_url"
        case oauth = "oauth_server_base_url"
        case profile = "profile_server_base_url"
        case token = "sync_tokenserver_base_url"
    }

    init() {}

    init(discoveryDocument json: JSONValue) {
        self.init()
        if let value = json[WellKnown.oauth.rawValue]?.stringValue, let url = URL(string: value) {
            oauthServer = Self.versioned(url)
        }
        if let value = json[WellKnown.profile.rawValue]?.stringValue, let url = URL(string: value)
        {
            profileServer = Self.versioned(url)
        }
        if let value = json[WellKnown.token.rawValue]?.stringValue, let url = URL(string: value) {
            // The token server's path (`/1.0/sync/1.5`) is supplied by the
            // caller, so its base is taken exactly as given.
            tokenServer = url
        }
    }

    /// The discovery document hands back **bare origins** —
    /// `https://oauth.accounts.firefox.com`, no path — while every endpoint on
    /// them lives under `/v1`. Our fallback constants have the `/v1`;
    /// discovery, which is supposed to be an improvement on them, silently
    /// removed it, and the code exchange then POSTed to `/token` and got a 404
    /// after the password had already been typed. Found by the #008AA
    /// diagnostics on their first run against the live server.
    ///
    /// Idempotent: a document that grows the `/v1` back is not given two.
    static func versioned(_ url: URL) -> URL {
        let last = url.pathComponents.last ?? ""
        let isVersion =
            last.count > 1 && last.hasPrefix("v") && last.dropFirst().allSatisfy(\.isNumber)
        return isVersion ? url : url.appendingPathComponent("v1")
    }
}

/// What a completed sign-in leaves behind. The refresh token is the long-lived
/// secret; the access token is minutes-to-hours and is re-minted from it.
struct FxAOAuthTokens: Equatable, Sendable, Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scopes: [String]
    /// nil when the response carried no `keys_jwe` — which means no sync.
    var scopedKey: ScopedKey?

    func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}

/// The authorization request, kept together because the verifier and the
/// ephemeral key have to survive until the code comes back. `Identifiable` so
/// it can drive a `.sheet(item:)` — a new request is a new sheet.
struct FxAAuthorizationRequest: Sendable, Identifiable {
    var id: String { state }

    let url: URL
    let state: String
    let pkce: PKCEChallenge
    let ephemeralKey: P256.KeyAgreement.PrivateKey
}

struct FxAOAuthClient: Sendable {
    let endpoints: FxAEndpoints
    let transport: HTTPTransport

    init(endpoints: FxAEndpoints = .fallback, transport: HTTPTransport = URLSessionTransport()) {
        self.endpoints = endpoints
        self.transport = transport
    }

    // MARK: Discovery

    static func discoverEndpoints(transport: HTTPTransport = URLSessionTransport()) async
        -> FxAEndpoints
    {
        do {
            let response = try await transport.send(
                URLRequest(url: SyncConfig.clientConfigurationURL))
            guard response.isSuccess else { return .fallback }
            return FxAEndpoints(discoveryDocument: try JSONValue(jsonData: response.body))
        } catch {
            // Discovery is an optimisation. Falling back is correct, and much
            // better than refusing to sign in because a well-known URL moved.
            return .fallback
        }
    }

    // MARK: Step 1–2 — the authorization URL

    func authorizationRequest(
        state: String = Data.randomBytes(16).base64URLString,
        pkce: PKCEChallenge = PKCEChallenge(),
        ephemeralKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
        email: String? = nil
    ) throws -> FxAAuthorizationRequest {
        var components = URLComponents(
            url: endpoints.contentServer.appendingPathComponent("authorization"),
            resolvingAgainstBaseURL: false)!

        let keysJWK = try ScopedKeyJWE.jwk(for: ephemeralKey.publicKey)
            .serializedData().base64URLString

        var items = [
            URLQueryItem(name: "client_id", value: SyncConfig.oauthClientID),
            URLQueryItem(name: "redirect_uri", value: SyncConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: SyncConfig.scopeString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            // Without this the response has no refresh token and sync dies
            // the first time the access token expires.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "keys_jwk", value: keysJWK),
            // Without these two the content server finishes the flow by
            // *navigating* to `redirect_uri` — which this client id does not
            // do, so nothing ever arrives and the sheet hangs (#008AA). With
            // them the result comes back over the WebChannel instead. Firefox
            // for iOS sends the same pair.
            URLQueryItem(name: "context", value: SyncConfig.webChannelContext),
            URLQueryItem(name: "action", value: SyncConfig.webChannelAction),
        ]
        if let email, !email.isEmpty { items.append(URLQueryItem(name: "email", value: email)) }
        components.queryItems = items

        guard let url = components.url else { throw SyncError.message("Bad authorization URL") }
        return FxAAuthorizationRequest(
            url: url, state: state, pkce: pkce, ephemeralKey: ephemeralKey)
    }

    /// Pull `code` out of the redirect, checking `state` first. A mismatched
    /// state means someone else's authorization is being replayed at us.
    static func authorizationCode(fromCallback url: URL, expectedState: String) throws -> String {
        // Read the query off the raw string rather than through URLComponents:
        // a native-app redirect may be a non-hierarchical URI (`urn:…?code=…`),
        // which URLComponents declines to parse a query out of, and this has to
        // keep working if the registered redirect ever changes back to one.
        let raw = url.absoluteString
        let query = raw.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
        var pairs: [String: String] = [:]
        for field in (query ?? "").split(separator: "&") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard let name = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            pairs[String(name)] = value.removingPercentEncoding ?? value
        }
        if let error = pairs["error"] {
            throw SyncError.message(pairs["error_description"] ?? "Sign-in failed: \(error)")
        }
        guard let state = pairs["state"], state == expectedState else {
            throw SyncError.message("Sign-in response did not match this request.")
        }
        guard let code = pairs["code"], !code.isEmpty else {
            throw SyncError.message("Sign-in response carried no authorization code.")
        }
        return code
    }

    /// The WebChannel equivalent of the above: `fxaccounts:oauth_login` brings
    /// the code and the state in a message rather than in a URL, and the state
    /// has to be checked just as hard. A page that manufactures a login is the
    /// attack this stops — it cannot know the state we generated.
    static func authorizationCode(
        fromWebChannel login: FxAWebChannelOAuthLogin, expectedState: String
    ) throws -> String {
        guard login.state == expectedState else {
            throw SyncError.message("Sign-in response did not match this request.")
        }
        guard !login.code.isEmpty else {
            throw SyncError.message("Sign-in response carried no authorization code.")
        }
        return login.code
    }

    // MARK: Step 4–5 — code for tokens, JWE for the scoped key

    func exchange(code: String, request: FxAAuthorizationRequest) async throws -> FxAOAuthTokens {
        let body = JSONValue.object([
            "client_id": .string(SyncConfig.oauthClientID),
            "code": .string(code),
            "code_verifier": .string(request.pkce.verifier),
        ])
        let json = try await postJSON(path: "token", body: body)
        return try tokens(from: json, ephemeralKey: request.ephemeralKey)
    }

    /// Mint a fresh access token. The response has no `keys_jwe` — scoped keys
    /// are delivered once, at sign-in, and stored.
    func refresh(refreshToken: String) async throws -> FxAOAuthTokens {
        let body = JSONValue.object([
            "client_id": .string(SyncConfig.oauthClientID),
            "grant_type": .string("refresh_token"),
            "refresh_token": .string(refreshToken),
            "scope": .string(SyncConfig.scopeString),
        ])
        let json = try await postJSON(path: "token", body: body)
        var tokens = try self.tokens(from: json, ephemeralKey: nil)
        // A refresh response usually omits the refresh token; keep ours.
        tokens.refreshToken = tokens.refreshToken ?? refreshToken
        return tokens
    }

    /// Best-effort — a failure here is not worth showing anyone, but leaving a
    /// live refresh token on Mozilla's servers after a sign-out would be rude.
    func revoke(refreshToken: String) async {
        _ = try? await postJSON(
            path: "destroy",
            body: .object([
                "client_id": .string(SyncConfig.oauthClientID),
                "refresh_token": .string(refreshToken),
            ]))
    }

    func profile(accessToken: String) async throws -> (email: String?, displayName: String?) {
        var request = URLRequest(url: endpoints.profileServer.appendingPathComponent("profile"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        guard response.isSuccess else { throw Self.error(from: response) }
        let json = try JSONValue(jsonData: response.body)
        return (json["email"]?.stringValue, json["displayName"]?.stringValue)
    }

    // MARK: Plumbing

    private func tokens(from json: JSONValue, ephemeralKey: P256.KeyAgreement.PrivateKey?)
        throws -> FxAOAuthTokens
    {
        guard let accessToken = json["access_token"]?.stringValue else {
            throw SyncError.message("The account server returned no access token.")
        }
        let lifetime = json["expires_in"]?.doubleValue ?? 3600
        var scopedKey: ScopedKey?
        if let jwe = json["keys_jwe"]?.stringValue, let ephemeralKey {
            let plaintext = try ScopedKeyJWE.decrypt(jwe, with: ephemeralKey)
            scopedKey = try ScopedKeyJWE.scopedKey(
                SyncKeyBundle.oldSyncScope, fromPlaintext: plaintext)
        }
        return FxAOAuthTokens(
            accessToken: accessToken,
            refreshToken: json["refresh_token"]?.stringValue,
            expiresAt: Date().addingTimeInterval(lifetime),
            scopes: (json["scope"]?.stringValue ?? SyncConfig.scopeString)
                .split(separator: " ").map(String.init),
            scopedKey: scopedKey)
    }

    private func postJSON(path: String, body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: endpoints.oauthServer.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.serializedData()
        let response = try await transport.send(request)
        guard response.isSuccess else { throw Self.error(from: response) }
        guard !response.body.isEmpty else { return .object([:]) }
        return try JSONValue(jsonData: response.body)
    }

    /// FxA errors come back as `{errno, error, message}`; the message is the
    /// only part worth showing.
    static func error(from response: HTTPResponse) -> SyncError {
        if response.status == 401 || response.status == 400,
            let json = try? JSONValue(jsonData: response.body),
            let errno = json["errno"]?.intValue,
            errno == 110 || errno == 108
        {
            return .authenticationExpired
        }
        let message =
            (try? JSONValue(jsonData: response.body))?["message"]?.stringValue ?? ""
        if response.status == 401 { return .authenticationExpired }
        return .server(status: response.status, message: message)
    }
}
