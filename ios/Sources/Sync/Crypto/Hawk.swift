//  Hawk.swift
//  Hawk request signing (`hawk.1.header`), as the Sync storage servers want it.
//
//  The token server hands out an `id` and a `key`; every storage request is
//  signed with them. The normalised string is newline-delimited and *exactly*
//  nine lines plus a trailing newline — a missing empty line for an absent
//  payload hash is the single most common way to get a 401 here, so the shape
//  is written out literally rather than assembled conditionally.

import CryptoKit
import Foundation

struct HawkCredentials: Equatable, Sendable {
    let id: String
    /// The token server returns this as text; it is used as HMAC key bytes.
    let key: Data

    init(id: String, key: Data) {
        self.id = id
        self.key = key
    }

    init(id: String, key: String) {
        self.init(id: id, key: Data(key.utf8))
    }
}

enum Hawk {

    /// `hash` in the `Authorization` header — SHA-256 over a normalised
    /// payload string, base64. Only sent when there is a body.
    static func payloadHash(_ payload: Data, contentType: String) -> String {
        var normalised = "hawk.1.payload\n"
        normalised += normalisedContentType(contentType) + "\n"
        var data = Data(normalised.utf8)
        data.append(payload)
        data.append(Data("\n".utf8))
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    /// The exact string the MAC is taken over. Exposed so a test can assert on
    /// it rather than only on the resulting MAC.
    static func normalisedRequestString(
        timestamp: Int, nonce: String, method: String, requestURI: String,
        host: String, port: Int, payloadHash: String, ext: String
    ) -> String {
        [
            "hawk.1.header",
            String(timestamp),
            nonce,
            method.uppercased(),
            requestURI,
            host.lowercased(),
            String(port),
            payloadHash,
            ext,
            "",
        ].joined(separator: "\n")
    }

    static func mac(
        credentials: HawkCredentials, timestamp: Int, nonce: String, method: String,
        requestURI: String, host: String, port: Int, payloadHash: String = "", ext: String = ""
    ) -> String {
        let normalised = normalisedRequestString(
            timestamp: timestamp, nonce: nonce, method: method, requestURI: requestURI,
            host: host, port: port, payloadHash: payloadHash, ext: ext)
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: Data(normalised.utf8), using: SymmetricKey(data: credentials.key))
        ).base64EncodedString()
    }

    /// The full `Authorization` value for a request. `payload`/`contentType`
    /// are only supplied when the request has a body we want covered.
    static func authorizationHeader(
        credentials: HawkCredentials, method: String, url: URL,
        payload: Data? = nil, contentType: String? = nil,
        timestamp: Int = Int(Date().timeIntervalSince1970),
        nonce: String = Data.randomBytes(6).base64URLString,
        ext: String = ""
    ) -> String {
        let host = url.host ?? ""
        let port = url.port ?? defaultPort(forScheme: url.scheme)
        var hash = ""
        if let payload, let contentType {
            hash = payloadHash(payload, contentType: contentType)
        }
        let signature = mac(
            credentials: credentials, timestamp: timestamp, nonce: nonce, method: method,
            requestURI: requestURI(for: url), host: host, port: port, payloadHash: hash, ext: ext)

        var fields = [
            "id=\"\(credentials.id)\"",
            "ts=\"\(timestamp)\"",
            "nonce=\"\(nonce)\"",
        ]
        if !hash.isEmpty { fields.append("hash=\"\(hash)\"") }
        if !ext.isEmpty { fields.append("ext=\"\(ext)\"") }
        fields.append("mac=\"\(signature)\"")
        return "Hawk " + fields.joined(separator: ", ")
    }

    /// Path plus query, which is what Hawk signs — never the whole URL.
    static func requestURI(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.path
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        guard let query = components.percentEncodedQuery, !query.isEmpty else { return path }
        return path + "?" + query
    }

    static func defaultPort(forScheme scheme: String?) -> Int {
        scheme?.lowercased() == "http" ? 80 : 443
    }

    /// Hawk signs the media type only — parameters such as `; charset=utf-8`
    /// are stripped, because proxies add and remove them freely.
    private static func normalisedContentType(_ contentType: String) -> String {
        contentType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? contentType.lowercased()
    }
}
