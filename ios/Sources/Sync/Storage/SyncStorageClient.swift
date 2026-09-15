//  SyncStorageClient.swift
//  A Sync 1.5 storage client: collections in, collections out.
//
//  The protocol is small but has three rules that are easy to get wrong and
//  expensive to get wrong:
//
//  · **`X-If-Unmodified-Since` on every write.** Without it two devices racing
//    on the same collection silently clobber each other. A 412 means "someone
//    else wrote first" — refetch and merge, never retry blindly.
//  · **Batching.** A POST may carry at most 100 records or a megabyte. Larger
//    uploads use the batch protocol (`?batch=true`, then `?batch=<id>`, then
//    `&commit=true`), which makes the whole set land atomically with one
//    timestamp.
//  · **Backoff.** `X-Weave-Backoff` and `Retry-After` are instructions, not
//    hints. A client that ignores them gets the account throttled.

import Foundation

/// The result of a write: the server's new timestamp for the collection, plus
/// which records it refused.
struct PostResult: Equatable, Sendable {
    var modified: Double
    var success: [String] = []
    var failed: [String: String] = [:]
    var batchID: String?
}

actor SyncStorageClient {

    private let transport: HTTPTransport
    private var token: TokenServerToken
    /// Set by `X-Weave-Backoff` / `Retry-After`; nothing is sent before it.
    private(set) var backoffUntil: Date?

    /// Called when the token expires mid-sync, to get a fresh one.
    private let renewToken: @Sendable () async throws -> TokenServerToken

    init(
        token: TokenServerToken,
        transport: HTTPTransport = URLSessionTransport(),
        renewToken: @escaping @Sendable () async throws -> TokenServerToken
    ) {
        self.token = token
        self.transport = transport
        self.renewToken = renewToken
    }

    // MARK: Reads

    /// `info/collections` — the cheapest possible "did anything change?".
    func infoCollections() async throws -> [String: Double] {
        let response = try await send(method: "GET", path: "info/collections")
        let json = try JSONValue(jsonData: response.body)
        return (json.objectValue ?? [:]).compactMapValues(\.doubleValue)
    }

    func metaGlobal() async throws -> (meta: MetaGlobal, modified: Double)? {
        guard let bso = try await getBSO(collection: "meta", id: "global") else { return nil }
        return (MetaGlobal(json: try JSONValue(jsonString: bso.payload)), bso.modified ?? 0)
    }

    /// `crypto/keys` is encrypted under the account's sync key, not under a
    /// collection key — it is what the collection keys come from.
    func cryptoKeys(syncKey: SyncKeyBundle) async throws -> CollectionKeys? {
        guard let bso = try await getBSO(collection: "crypto", id: "keys") else { return nil }
        let payload = try JSONDecoder().decode(
            EncryptedPayload.self, from: Data(bso.payload.utf8))
        let json = try BSOCrypto.decryptJSON(payload, with: syncKey)
        guard let keys = CollectionKeys(json: json) else {
            throw SyncError.cryptoKeysUnavailable
        }
        return keys
    }

    func getBSO(collection: String, id: String) async throws -> BasicStorageObject? {
        let response = try await send(
            method: "GET", path: "storage/\(collection)/\(id)")
        if response.status == 404 { return nil }
        return try JSONDecoder().decode(BasicStorageObject.self, from: response.body)
    }

    /// Fetch a whole collection, decrypting as we go.
    ///
    /// `newer` is the last timestamp we successfully processed: passing it is
    /// what makes an incremental sync incremental. `limit` + the `X-Weave-Next-Offset`
    /// header page through collections too large for one response.
    func fetch(
        collection: String, bundle: SyncKeyBundle, newer: Double? = nil, limit: Int = 500,
        ids: [String]? = nil
    ) async throws -> (records: [DecryptedRecord], modified: Double) {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "full", value: "1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let newer, newer > 0 {
            query.append(URLQueryItem(name: "newer", value: Self.format(newer)))
        }
        if let ids, !ids.isEmpty {
            query.append(URLQueryItem(name: "ids", value: ids.joined(separator: ",")))
        }

        var all: [DecryptedRecord] = []
        var modified: Double = 0
        var offset: String?
        repeat {
            var page = query
            if let offset { page.append(URLQueryItem(name: "offset", value: offset)) }
            let response = try await send(
                method: "GET", path: "storage/\(collection)", query: page)
            if response.status == 404 { return ([], 0) }
            modified = max(modified, Self.timestamp(response) ?? 0)

            let bsos = try JSONDecoder().decode([BasicStorageObject].self, from: response.body)
            for bso in bsos {
                all.append(try Self.decrypt(bso, collection: collection, bundle: bundle))
            }
            offset = response.header("X-Weave-Next-Offset")
        } while offset != nil

        return (all, modified)
    }

    static func decrypt(_ bso: BasicStorageObject, collection: String, bundle: SyncKeyBundle)
        throws -> DecryptedRecord
    {
        let payload: JSONValue
        do {
            let encrypted = try JSONDecoder().decode(
                EncryptedPayload.self, from: Data(bso.payload.utf8))
            payload = try BSOCrypto.decryptJSON(encrypted, with: bundle)
        } catch {
            throw SyncError.decryptionFailed(collection: collection, id: bso.id)
        }
        return DecryptedRecord(
            id: bso.id, modified: bso.modified ?? 0, payload: payload, sortindex: bso.sortindex)
    }

    // MARK: Writes

    func put(collection: String, id: String, payload: String, unmodifiedSince: Double?)
        async throws -> Double
    {
        let bso = BasicStorageObject(id: id, payload: payload)
        let body = try JSONEncoder().encode(bso)
        let response = try await send(
            method: "PUT", path: "storage/\(collection)/\(id)", body: body,
            unmodifiedSince: unmodifiedSince)
        return Self.timestamp(response) ?? 0
    }

    /// Encrypt and upload a set of records, batching as the protocol requires.
    /// Returns the collection's new timestamp.
    @discardableResult
    func post(
        collection: String, records: [DecryptedRecord], bundle: SyncKeyBundle,
        unmodifiedSince: Double?
    ) async throws -> PostResult {
        guard !records.isEmpty else {
            return PostResult(modified: unmodifiedSince ?? 0)
        }

        let bsos: [BasicStorageObject] = try records.map { record in
            let encrypted = try BSOCrypto.encryptJSON(record.payload, with: bundle)
            let payload = String(
                decoding: try JSONEncoder().encode(encrypted), as: UTF8.self)
            return BasicStorageObject(
                id: record.id, payload: payload, sortindex: record.sortindex)
        }

        let chunks = Self.chunk(bsos)
        var result = PostResult(modified: unmodifiedSince ?? 0)
        var batchID: String?
        var since = unmodifiedSince

        for (index, chunk) in chunks.enumerated() {
            let isLast = index == chunks.count - 1
            var query: [URLQueryItem] = []
            if chunks.count > 1 || batchID != nil {
                query.append(
                    URLQueryItem(name: "batch", value: batchID ?? "true"))
                if isLast { query.append(URLQueryItem(name: "commit", value: "true")) }
            }

            let body = try JSONEncoder().encode(chunk)
            let response = try await send(
                method: "POST", path: "storage/\(collection)", query: query, body: body,
                unmodifiedSince: since)

            let json = try JSONValue(jsonData: response.body)
            result.success += json["success"]?.arrayValue?.compactMap(\.stringValue) ?? []
            for (id, reason) in json["failed"]?.objectValue ?? [:] {
                result.failed[id] = reason.stringValue ?? "rejected"
            }
            if let id = json["batch"]?.stringValue {
                batchID = id
                result.batchID = id
            }
            // Only the committing response carries the collection's new
            // timestamp; a 202 in the middle of a batch does not.
            if let stamp = Self.timestamp(response), response.status != 202 {
                result.modified = stamp
                since = stamp
            }
        }
        return result
    }

    func delete(collection: String, ids: [String], unmodifiedSince: Double?) async throws {
        guard !ids.isEmpty else { return }
        for chunk in stride(from: 0, to: ids.count, by: SyncConfig.maxPostRecords).map({
            Array(ids[$0..<min($0 + SyncConfig.maxPostRecords, ids.count)])
        }) {
            _ = try await send(
                method: "DELETE", path: "storage/\(collection)",
                query: [URLQueryItem(name: "ids", value: chunk.joined(separator: ","))],
                unmodifiedSince: unmodifiedSince)
        }
    }

    // MARK: Chunking

    /// Split into POSTs that respect both of the server's limits. A single
    /// record larger than the byte limit still goes on its own — the server
    /// will reject it, and that is a clearer failure than silently dropping it.
    static func chunk(
        _ bsos: [BasicStorageObject], maxRecords: Int = SyncConfig.maxPostRecords,
        maxBytes: Int = SyncConfig.maxPostBytes
    ) -> [[BasicStorageObject]] {
        var chunks: [[BasicStorageObject]] = []
        var current: [BasicStorageObject] = []
        var bytes = 2  // the enclosing `[]`

        for bso in bsos {
            let size = bso.payload.utf8.count + bso.id.utf8.count + 64
            if !current.isEmpty && (current.count >= maxRecords || bytes + size > maxBytes) {
                chunks.append(current)
                current = []
                bytes = 2
            }
            current.append(bso)
            bytes += size
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: Request plumbing

    func url(path: String, query: [URLQueryItem]) -> URL {
        var base = token.storageEndpoint
        for component in path.split(separator: "/") {
            base = base.appendingPathComponent(String(component))
        }
        guard !query.isEmpty,
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return base }
        components.queryItems = query
        return components.url ?? base
    }

    private func send(
        method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil,
        unmodifiedSince: Double? = nil, isRetry: Bool = false
    ) async throws -> HTTPResponse {
        if let until = backoffUntil, until > Date() {
            throw SyncError.backoff(seconds: until.timeIntervalSinceNow)
        }

        let url = url(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        let contentType = body == nil ? nil : "application/json"
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let unmodifiedSince {
            request.setValue(
                Self.format(unmodifiedSince), forHTTPHeaderField: "X-If-Unmodified-Since")
        }
        request.setValue(
            Hawk.authorizationHeader(
                credentials: token.credentials, method: method, url: url, payload: body,
                contentType: contentType),
            forHTTPHeaderField: "Authorization")

        let response = try await transport.send(request)
        noteBackoff(response)

        switch response.status {
        case 401:
            // The Hawk credentials expired mid-sync. One renewal, then give up —
            // retrying forever on a revoked account is how you get rate-limited.
            guard !isRetry else { throw SyncError.authenticationExpired }
            token = try await renewToken()
            return try await send(
                method: method, path: path, query: query, body: body,
                unmodifiedSince: unmodifiedSince, isRetry: true)
        case 412:
            throw SyncError.server(
                status: 412, message: "The collection changed while we were writing to it.")
        case 503, 500, 502, 504:
            let retry = Self.retryAfter(response) ?? 60
            backoffUntil = Date().addingTimeInterval(retry)
            throw SyncError.backoff(seconds: retry)
        case 404:
            return response
        default:
            guard response.isSuccess else {
                throw SyncError.server(
                    status: response.status,
                    message: String(decoding: response.body.prefix(200), as: UTF8.self))
            }
            return response
        }
    }

    private func noteBackoff(_ response: HTTPResponse) {
        // X-Weave-Backoff applies to the whole service and is advisory for the
        // *next* sync; Retry-After comes with a refusal and applies now.
        if let value = response.header("X-Weave-Backoff").flatMap(TimeInterval.init), value > 0 {
            backoffUntil = Date().addingTimeInterval(value)
        }
        if let value = Self.retryAfter(response), value > 0 {
            backoffUntil = Date().addingTimeInterval(value)
        }
    }

    func clearBackoff() { backoffUntil = nil }

    func currentToken() -> TokenServerToken { token }

    static func retryAfter(_ response: HTTPResponse) -> TimeInterval? {
        response.header("Retry-After").flatMap(TimeInterval.init)
    }

    static func timestamp(_ response: HTTPResponse) -> Double? {
        response.header("X-Last-Modified").flatMap(Double.init)
            ?? response.header("X-Weave-Timestamp").flatMap(Double.init)
    }

    /// Sync timestamps are seconds with exactly two decimal places. Sending
    /// `1.7e9` or full double precision gets a 400.
    static func format(_ timestamp: Double) -> String {
        String(format: "%.2f", timestamp)
    }
}
