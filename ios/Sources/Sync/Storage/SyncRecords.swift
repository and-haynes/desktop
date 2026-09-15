//  SyncRecords.swift
//  The record types Sync 1.5 puts in every collection.
//
//  A BSO ("basic storage object") is the envelope: an id, the server's
//  modification time, and a `payload` that is a *string* — JSON inside JSON,
//  because the server never looks inside it. For every collection except
//  `meta` and `crypto` that string is an encrypted payload.

import CryptoKit
import Foundation

/// A record exactly as the server stores it.
struct BasicStorageObject: Codable, Equatable, Sendable {
    var id: String
    /// Server-assigned, in seconds with two decimal places.
    var modified: Double?
    var sortindex: Int?
    var ttl: Int?
    var payload: String

    init(id: String, payload: String, modified: Double? = nil, sortindex: Int? = nil,
         ttl: Int? = nil) {
        self.id = id
        self.payload = payload
        self.modified = modified
        self.sortindex = sortindex
        self.ttl = ttl
    }
}

/// A BSO whose payload has been decrypted. `deleted` is a field *inside* the
/// payload, not a property of the envelope — a tombstone is an ordinary record
/// that says `{"id": …, "deleted": true}`.
struct DecryptedRecord: Equatable, Sendable {
    var id: String
    var modified: Double
    var payload: JSONValue
    var sortindex: Int?

    var isDeleted: Bool { payload["deleted"]?.boolValue == true }

    /// Zen's spaces records wrap their content in `{id, kind, data}`.
    var kind: String? { payload["kind"]?.stringValue }
    var data: JSONValue? { payload["data"] }
}

/// `meta/global` — the account's storage format and per-engine sync ids.
/// A changed `syncID` means "throw away what you have for that engine".
struct MetaGlobal: Equatable, Sendable {
    var syncID: String
    var storageVersion: Int
    /// engine name → (version, syncID)
    var engines: [String: EngineMeta]
    var declined: [String]

    struct EngineMeta: Equatable, Sendable {
        var version: Int
        var syncID: String
    }

    init(
        syncID: String = SyncGUID.generate(), storageVersion: Int = SyncConfig.storageVersion,
        engines: [String: EngineMeta] = [:], declined: [String] = []
    ) {
        self.syncID = syncID
        self.storageVersion = storageVersion
        self.engines = engines
        self.declined = declined
    }

    init(json: JSONValue) {
        syncID = json["syncID"]?.stringValue ?? ""
        storageVersion = json["storageVersion"]?.intValue ?? 0
        declined = json["declined"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var engines: [String: EngineMeta] = [:]
        for (name, value) in json["engines"]?.objectValue ?? [:] {
            engines[name] = EngineMeta(
                version: value["version"]?.intValue ?? 0,
                syncID: value["syncID"]?.stringValue ?? "")
        }
        self.engines = engines
    }

    var json: JSONValue {
        var engineObject: [String: JSONValue] = [:]
        for (name, meta) in engines {
            engineObject[name] = .object([
                "version": .number(Double(meta.version)),
                "syncID": .string(meta.syncID),
            ])
        }
        return .object([
            "syncID": .string(syncID),
            "storageVersion": .number(Double(storageVersion)),
            "engines": .object(engineObject),
            "declined": .array(declined.map { .string($0) }),
        ])
    }
}

/// `crypto/keys` — the per-collection key bundles, themselves encrypted under
/// the sync key. One indirection so that changing the account password can
/// re-key everything without re-encrypting every record.
struct CollectionKeys: Equatable, Sendable, Codable {
    var defaultBundle: SyncKeyBundleBox
    var collections: [String: SyncKeyBundleBox]

    /// `SyncKeyBundle` is not `Codable` (it is a pair of raw keys and should
    /// stay awkward to serialise by accident); this box is the deliberate way.
    struct SyncKeyBundleBox: Equatable, Sendable, Codable {
        var encryptionKey: Data
        var hmacKey: Data

        init(_ bundle: SyncKeyBundle) {
            encryptionKey = bundle.encryptionKey
            hmacKey = bundle.hmacKey
        }

        var bundle: SyncKeyBundle? {
            SyncKeyBundle(encryptionKey: encryptionKey, hmacKey: hmacKey)
        }
    }

    init(defaultBundle: SyncKeyBundle, collections: [String: SyncKeyBundle] = [:]) {
        self.defaultBundle = SyncKeyBundleBox(defaultBundle)
        self.collections = collections.mapValues(SyncKeyBundleBox.init)
    }

    init?(json: JSONValue) {
        guard let pair = json["default"]?.arrayValue?.compactMap(\.stringValue),
            let bundle = SyncKeyBundle(base64Pair: pair)
        else { return nil }
        var collections: [String: SyncKeyBundle] = [:]
        for (name, value) in json["collections"]?.objectValue ?? [:] {
            if let pair = value.arrayValue?.compactMap(\.stringValue),
                let bundle = SyncKeyBundle(base64Pair: pair)
            {
                collections[name] = bundle
            }
        }
        self.init(defaultBundle: bundle, collections: collections)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        for (name, box) in collections {
            guard let bundle = box.bundle else { continue }
            object[name] = .array(bundle.base64Pair.map { .string($0) })
        }
        return .object([
            "id": .string("keys"),
            "default": .array((defaultBundle.bundle?.base64Pair ?? []).map { .string($0) }),
            "collections": .object(object),
        ])
    }

    /// The bundle a given collection's records are sealed with.
    func bundle(for collection: String) -> SyncKeyBundle? {
        (collections[collection] ?? defaultBundle).bundle
    }

    /// A brand-new account needs keys before anything can be written.
    static func generate() -> CollectionKeys {
        CollectionKeys(defaultBundle: SyncKeyBundle(keyMaterial: Data.randomBytes(64))!)
    }
}

/// Sync's identifier format: 12 base64url characters (9 random bytes).
/// Bookmarks and history records *must* use it — the desktop validates.
/// Zen's spaces engine does not: it uses the browser's own uuids.
enum SyncGUID {
    static func generate() -> String {
        Data.randomBytes(9).base64URLString
    }

    static func isValid(_ guid: String) -> Bool {
        guid.count == 12 && guid.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    /// A stable guid for a local object, so the same bookmark keeps its
    /// identity across launches without a side table: SHA-256 of the local
    /// uuid, truncated to Sync's 9 bytes.
    static func derived(from seed: String) -> String {
        Data(SHA256.hash(data: Data(seed.utf8)).prefix(9)).base64URLString
    }
}
