//  TokenServerClient.swift
//  OAuth token + X-KeyID → a storage node and Hawk credentials.
//
//  The token server is the piece that turns "this person" into "this person's
//  shard": it allocates the account to a storage node, and returns short-lived
//  Hawk credentials scoped to it. The `X-KeyID` header is the scoped key's
//  `kid` — it lets the server notice that the account's keys have been rotated
//  (a password reset) and refuse to hand out access to data encrypted under
//  the old one.

import Foundation

struct TokenServerToken: Equatable, Sendable, Codable {
    let hawkID: String
    let hawkKey: String
    /// Numeric account id; it appears in every storage path.
    let uid: Int
    /// Base URL of the storage node, e.g. `https://sync-1-us-west1-g.sync.services.mozilla.com/1.5/12345`.
    let storageEndpoint: URL
    let expiresAt: Date
    /// Stable, hashed account identifier. Handy in logs, safe to keep.
    let hashedFxAUID: String

    var credentials: HawkCredentials { HawkCredentials(id: hawkID, key: hawkKey) }

    func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}

struct TokenServerClient: Sendable {
    let baseURL: URL
    let transport: HTTPTransport

    init(
        baseURL: URL = SyncConfig.defaultTokenServer,
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    var url: URL {
        URL(string: SyncConfig.tokenServerPath, relativeTo: baseURL)?.absoluteURL
            ?? baseURL.appendingPathComponent(SyncConfig.tokenServerPath)
    }

    func token(accessToken: String, keyID: String) async throws -> TokenServerToken {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(keyID, forHTTPHeaderField: "X-KeyID")

        let response = try await transport.send(request)
        if response.status == 401 { throw SyncError.authenticationExpired }
        if response.status == 503, let retry = Self.retryAfter(response) {
            throw SyncError.backoff(seconds: retry)
        }
        guard response.isSuccess else {
            // 400 with `invalid-keyID` means the account's keys were rotated
            // under us — a password reset. Re-authenticating is the fix, and
            // it is the same fix as an expired session.
            let json = try? JSONValue(jsonData: response.body)
            let status = json?["status"]?.stringValue ?? ""
            if status.contains("keyID") || status == "invalid-credentials" {
                throw SyncError.authenticationExpired
            }
            throw SyncError.server(
                status: response.status,
                message: json?["message"]?.stringValue ?? status)
        }

        return try Self.parse(response)
    }

    static func parse(_ response: HTTPResponse) throws -> TokenServerToken {
        let json = try JSONValue(jsonData: response.body)
        guard let id = json["id"]?.stringValue,
            let key = json["key"]?.stringValue,
            let uid = json["uid"]?.intValue,
            let endpoint = json["api_endpoint"]?.stringValue.flatMap(URL.init(string:))
        else {
            throw SyncError.server(status: response.status, message: "Malformed token response")
        }
        let duration = json["duration"]?.doubleValue ?? 3600
        return TokenServerToken(
            hawkID: id, hawkKey: key, uid: uid, storageEndpoint: endpoint,
            expiresAt: Date().addingTimeInterval(duration),
            hashedFxAUID: json["hashed_fxa_uid"]?.stringValue ?? "")
    }

    static func retryAfter(_ response: HTTPResponse) -> TimeInterval? {
        response.header("Retry-After").flatMap(TimeInterval.init)
    }
}
