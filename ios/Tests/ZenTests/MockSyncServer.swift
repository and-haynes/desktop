//  MockSyncServer.swift
//  An in-memory Sync 1.5 storage server.
//
//  Enough of the protocol to drive a whole sync: `info/collections`,
//  `meta/global`, `crypto/keys`, GET and POST on collections with `full`,
//  `newer` and `ids`, `X-If-Unmodified-Since` (returning a real 412), the
//  batch parameters, and per-collection timestamps that advance on write.
//
//  It deliberately does *not* decrypt anything: records go in and come out as
//  opaque payloads, exactly as the real server treats them, so a test that
//  passes here is a test where our own encryption and decryption agreed.

import Foundation

@testable import Zen

final class MockSyncServer: HTTPTransport, @unchecked Sendable {

    struct Stored {
        var bso: BasicStorageObject
        var modified: Double
    }

    private let lock = NSLock()
    private var collections: [String: [String: Stored]] = [:]
    private var collectionModified: [String: Double] = [:]
    /// Server-assigned timestamps start at "now": a real storage server's
    /// clock agrees with the client's, and tests that assume otherwise pass
    /// for reasons that would not survive contact with one.
    private var clock: Double = (Date().timeIntervalSince1970 * 100).rounded() / 100
    private var batches: [String: [BasicStorageObject]] = [:]

    /// Queued (status, headers) overrides — pop one per request. Used to test
    /// backoff and 401 renewal without pretending to be a flaky network.
    var scriptedResponses: [HTTPResponse] = []
    /// Every request the client made, for assertions about headers.
    private(set) var requests: [URLRequest] = []

    let hawkCredentials = HawkCredentials(id: "mock-id", key: "mock-key")
    let storageEndpoint = URL(string: "https://sync.example/1.5/12345")!

    func token(expiresIn: TimeInterval = 3600) -> TokenServerToken {
        TokenServerToken(
            hawkID: hawkCredentials.id, hawkKey: "mock-key", uid: 12345,
            storageEndpoint: storageEndpoint,
            expiresAt: Date().addingTimeInterval(expiresIn), hashedFxAUID: "mock-uid")
    }

    func client() -> SyncStorageClient {
        let token = token()
        return SyncStorageClient(token: token, transport: self, renewToken: { token })
    }

    // MARK: Seeding

    /// Put a record in as if another device had uploaded it.
    func seed(collection: String, id: String, payload: String, modified: Double? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = modified ?? tick()
        collections[collection, default: [:]][id] = Stored(
            bso: BasicStorageObject(id: id, payload: payload, modified: stamp), modified: stamp)
        collectionModified[collection] = max(collectionModified[collection] ?? 0, stamp)
    }

    /// Encrypt and seed — the usual way a test plays "the desktop uploaded
    /// this".
    func seedEncrypted(
        collection: String, id: String, payload: JSONValue, bundle: SyncKeyBundle,
        modified: Double? = nil
    ) throws {
        let encrypted = try BSOCrypto.encryptJSON(payload, with: bundle)
        let text = String(decoding: try JSONEncoder().encode(encrypted), as: UTF8.self)
        seed(collection: collection, id: id, payload: text, modified: modified)
    }

    func records(in collection: String) -> [BasicStorageObject] {
        lock.lock()
        defer { lock.unlock() }
        return (collections[collection] ?? [:]).values.map(\.bso).sorted { $0.id < $1.id }
    }

    func decryptedRecords(in collection: String, bundle: SyncKeyBundle) throws
        -> [DecryptedRecord]
    {
        try records(in: collection).map {
            try SyncStorageClient.decrypt($0, collection: collection, bundle: bundle)
        }
    }

    func timestamp(of collection: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return collectionModified[collection]
    }

    private func tick() -> Double {
        clock += 0.01
        return (clock * 100).rounded() / 100
    }

    // MARK: HTTPTransport

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        // The lock is deliberately taken in a synchronous helper: NSLock is
        // unavailable from an async context, and the whole point of this
        // server is that it answers without suspending.
        respond(to: request)
    }

    private func respond(to request: URLRequest) -> HTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        if !scriptedResponses.isEmpty { return scriptedResponses.removeFirst() }

        guard let url = request.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return HTTPResponse(status: 400, headers: [:], body: Data()) }

        // Everything after `/1.5/<uid>/`.
        let prefix = storageEndpoint.path
        var path = components.path
        if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
        let segments = path.split(separator: "/").map(String.init)
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last })
        let method = request.httpMethod ?? "GET"

        switch segments.first {
        case "info" where segments.count > 1 && segments[1] == "collections":
            return json(collectionModified.mapValues { JSONValue.number($0) })

        case "storage" where segments.count == 3:
            return handleItem(
                collection: segments[1], id: segments[2], method: method, request: request)

        case "storage" where segments.count == 2:
            return handleCollection(
                collection: segments[1], method: method, query: query, request: request)

        default:
            return HTTPResponse(status: 404, headers: [:], body: Data())
        }
    }

    // MARK: Handlers

    private func handleItem(
        collection: String, id: String, method: String, request: URLRequest
    ) -> HTTPResponse {
        switch method {
        case "GET":
            guard let stored = collections[collection]?[id] else {
                return HTTPResponse(status: 404, headers: [:], body: Data())
            }
            let body = (try? JSONEncoder().encode(stored.bso)) ?? Data()
            return HTTPResponse(
                status: 200,
                headers: ["X-Last-Modified": String(format: "%.2f", stored.modified)], body: body)

        case "PUT":
            if let failure = precondition(collection: collection, request: request) {
                return failure
            }
            guard let body = request.httpBody,
                let bso = try? JSONDecoder().decode(BasicStorageObject.self, from: body)
            else { return HTTPResponse(status: 400, headers: [:], body: Data()) }
            let stamp = tick()
            collections[collection, default: [:]][id] = Stored(
                bso: BasicStorageObject(id: id, payload: bso.payload, modified: stamp),
                modified: stamp)
            collectionModified[collection] = stamp
            return HTTPResponse(
                status: 200, headers: ["X-Last-Modified": String(format: "%.2f", stamp)],
                body: Data(String(format: "%.2f", stamp).utf8))

        case "DELETE":
            collections[collection]?[id] = nil
            let stamp = tick()
            collectionModified[collection] = stamp
            return HTTPResponse(status: 204, headers: [:], body: Data())

        default:
            return HTTPResponse(status: 405, headers: [:], body: Data())
        }
    }

    private func handleCollection(
        collection: String, method: String, query: [String: String], request: URLRequest
    ) -> HTTPResponse {
        switch method {
        case "GET":
            var stored = (collections[collection] ?? [:]).values.sorted {
                $0.modified < $1.modified
            }
            if let newer = query["newer"].flatMap(Double.init) {
                stored = stored.filter { $0.modified > newer }
            }
            if let ids = query["ids"], !ids.isEmpty {
                let wanted = Set(ids.split(separator: ",").map(String.init))
                stored = stored.filter { wanted.contains($0.bso.id) }
            }
            let body = (try? JSONEncoder().encode(stored.map(\.bso))) ?? Data("[]".utf8)
            return HTTPResponse(
                status: 200,
                headers: [
                    "X-Last-Modified": String(
                        format: "%.2f", collectionModified[collection] ?? 0),
                    "X-Weave-Records": String(stored.count),
                ], body: body)

        case "POST":
            if let failure = precondition(collection: collection, request: request) {
                return failure
            }
            guard let body = request.httpBody,
                let bsos = try? JSONDecoder().decode([BasicStorageObject].self, from: body)
            else { return HTTPResponse(status: 400, headers: [:], body: Data()) }

            let batch = query["batch"]
            let commit = query["commit"] == "true"

            if let batch, batch != "true", !commit {
                batches[batch, default: []] += bsos
                return json(
                    ["batch": .string(batch), "success": .array([]), "failed": .object([:])],
                    status: 202)
            }
            if batch == "true" && !commit {
                let id = "batch-\(batches.count + 1)"
                batches[id] = bsos
                return json(
                    ["batch": .string(id), "success": .array([]), "failed": .object([:])],
                    status: 202)
            }

            var pending = bsos
            if let batch, batch != "true" {
                pending = (batches.removeValue(forKey: batch) ?? []) + bsos
            }

            let stamp = tick()
            var success: [JSONValue] = []
            for bso in pending {
                collections[collection, default: [:]][bso.id] = Stored(
                    bso: BasicStorageObject(
                        id: bso.id, payload: bso.payload, modified: stamp,
                        sortindex: bso.sortindex), modified: stamp)
                success.append(.string(bso.id))
            }
            collectionModified[collection] = stamp
            return json(
                ["success": .array(success), "failed": .object([:])],
                headers: ["X-Last-Modified": String(format: "%.2f", stamp)])

        case "DELETE":
            if let ids = query["ids"] {
                for id in ids.split(separator: ",") {
                    collections[collection]?[String(id)] = nil
                }
            } else {
                collections[collection] = [:]
            }
            let stamp = tick()
            collectionModified[collection] = stamp
            return HTTPResponse(status: 204, headers: [:], body: Data())

        default:
            return HTTPResponse(status: 405, headers: [:], body: Data())
        }
    }

    /// `X-If-Unmodified-Since` → 412 when the collection has moved on. This is
    /// the race two devices actually hit.
    private func precondition(collection: String, request: URLRequest) -> HTTPResponse? {
        guard
            let header = request.value(forHTTPHeaderField: "X-If-Unmodified-Since"),
            let since = Double(header)
        else { return nil }
        let current = collectionModified[collection] ?? 0
        // Two decimal places on both sides, so compare at that resolution.
        guard current > since + 0.005 else { return nil }
        return HTTPResponse(status: 412, headers: [:], body: Data())
    }

    private func json(
        _ object: [String: JSONValue], status: Int = 200, headers: [String: String] = [:]
    ) -> HTTPResponse {
        let body = (try? JSONValue.object(object).serializedData()) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: headers, body: body)
    }
}
