//  HTTPTransport.swift
//  The one seam between the sync code and the network.
//
//  Everything above this talks to `HTTPTransport`, so the storage client, the
//  token server and the OAuth exchange can all be driven by a mock in tests —
//  including the end-to-end spaces sync, which runs against an in-memory Sync
//  server rather than against Mozilla's.

import Foundation

struct HTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    /// HTTP header names are case-insensitive and servers disagree about
    /// casing, so never subscript `headers` directly.
    func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }

    var isSuccess: Bool { (200..<300).contains(status) }
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.transport("non-HTTP response")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// One error type for the whole stack, so a UI that shows "Sync failed"
/// can also show *why* without switching over five enums.
enum SyncError: Error, LocalizedError, Equatable {
    case notSignedIn
    case transport(String)
    /// The server said no. `status` is the HTTP code.
    case server(status: Int, message: String)
    /// Credentials are stale and a refresh did not fix it — the user has to
    /// sign in again.
    case authenticationExpired
    case scopedKeyMissing
    case storageVersionUnsupported(Int)
    case cryptoKeysUnavailable
    case decryptionFailed(collection: String, id: String)
    /// Server asked us to back off; nothing is wrong.
    case backoff(seconds: TimeInterval)
    case cancelled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to a Mozilla account."
        case .transport(let detail):
            return "Could not reach the sync server: \(detail)"
        case .server(let status, let message):
            return message.isEmpty
                ? "The sync server returned \(status)." : "\(message) (\(status))"
        case .authenticationExpired:
            return "Your Mozilla account session has expired. Sign in again."
        case .scopedKeyMissing:
            return "The account did not return a sync key."
        case .storageVersionUnsupported(let version):
            return
                "This account's sync data uses storage format \(version), which this "
                + "version of Zen does not understand."
        case .cryptoKeysUnavailable:
            return "The account's encryption keys could not be read."
        case .decryptionFailed(let collection, let id):
            return "A \(collection) record (\(id)) could not be decrypted."
        case .backoff(let seconds):
            return "The sync server asked for a pause of \(Int(seconds))s."
        case .cancelled:
            return "Sync was cancelled."
        case .message(let text):
            return text
        }
    }
}
