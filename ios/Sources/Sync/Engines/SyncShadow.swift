//  SyncShadow.swift
//  What the server is known to hold, and what we have changed since.
//
//  This is the same idea as `ZenSpacesSyncModel`'s `zen-spaces-sync.json` on
//  the desktop, and for the same reason: outgoing records are a *diff* between
//  what we would project right now and what the server last acknowledged, so
//  a sync that changes nothing uploads nothing. Three pieces:
//
//  · `uploaded` — id → digest of the payload the server holds. Equality is all
//    we ever ask, so short digests are cheaper than whole payloads.
//  · `retained` — id → the last payload we *saw*. Zen desktop's records carry
//    fields a phone has no concept of (containers, folders, split groups, the
//    gradient dots' `algorithm` and `lightness`). Projecting without them
//    would hand the desktop a lossy copy of its own state, which it would
//    dutifully re-upload, for ever. Retaining and merging them back stops the
//    ping-pong.
//  · `changedAt` — id → when we first noticed the local side had diverged.
//    This is the change journal: an edit made in a tunnel is stamped the
//    moment it happens, so when the phone next reaches the network the
//    last-writer-wins comparison against the server's timestamp is honest
//    rather than "whenever we got signal".
//
//  `held` is the counterpart to desktop's `pendingIds`: ids the server has
//  that we deliberately do not project (a folder, a split view). Their absence
//  from our projection is not a deletion and must never become a tombstone.

import Foundation

struct CollectionShadow: Codable, Equatable, Sendable {
    /// The newest `modified` we have processed. Passed as `newer=` next time.
    var lastModified: Double = 0
    /// From `meta/global`. A change means the collection was reset and
    /// everything we think we know about it is stale.
    var syncID: String = ""
    var uploaded: [String: String] = [:]
    var retained: [String: JSONValue] = [:]
    var changedAt: [String: Double] = [:]
    /// Ids deleted locally, awaiting a tombstone upload.
    var pendingDeletions: [String: Double] = [:]
    /// Ids present remotely that we do not model. Never tombstoned.
    var held: Set<String> = []

    /// Forget everything but the identity of the collection — what a changed
    /// `syncID` calls for.
    mutating func reset(syncID: String) {
        self.syncID = syncID
        lastModified = 0
        uploaded = [:]
        retained = [:]
        changedAt = [:]
        pendingDeletions = [:]
        held = []
    }

    /// Record that the server now holds exactly this payload for `id`.
    mutating func noteUploaded(id: String, payload: JSONValue) {
        uploaded[id] = payload.digest
        retained[id] = payload
        changedAt[id] = nil
        pendingDeletions[id] = nil
    }

    /// Record that an incoming payload was applied locally. Storing the
    /// *incoming* digest means a faithful local materialisation produces no
    /// re-upload, while a divergent one re-uploads the local truth on the next
    /// pass — self-healing, exactly as the desktop does it.
    mutating func noteApplied(id: String, payload: JSONValue?) {
        guard let payload else {
            uploaded[id] = nil
            retained[id] = nil
            changedAt[id] = nil
            return
        }
        uploaded[id] = payload.digest
        retained[id] = payload
        changedAt[id] = nil
    }

    mutating func noteDeletedLocally(id: String, at time: Double) {
        guard uploaded[id] != nil else {
            // Never uploaded, so there is nothing to tombstone.
            retained[id] = nil
            changedAt[id] = nil
            return
        }
        pendingDeletions[id] = time
        changedAt[id] = nil
    }
}

struct SyncShadow: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = SyncShadow.currentVersion
    var collections: [String: CollectionShadow] = [:]
    /// This device's `clients` record id. Stable for the life of the install.
    var clientGUID: String = SyncGUID.generate()
    /// `meta/global`'s own syncID; a change means the whole account was reset.
    var storageSyncID: String = ""
    var identities = SyncIdentityMap()
    /// Space uuid → the SF Symbol we substituted an emoji for on upload, so a
    /// round trip through our own device keeps the symbol the owner chose.
    var spaceSymbolShadow: [String: String] = [:]
    var lastSyncedAt: Date?

    subscript(collection: String) -> CollectionShadow {
        get { collections[collection] ?? CollectionShadow() }
        set { collections[collection] = newValue }
    }
}

/// Local `UUID` ↔ remote record id.
///
/// Zen's own identifiers are not UUIDs, so we cannot simply reuse ours:
/// a space's `uuid` is `Services.uuid.generateUUID().toString()` — which keeps
/// the **braces**, `{5f8c…}` — and a tab's `zenSyncId` is
/// `` `${Date.now()}-${Math.round(Math.random()*100)}` ``. Getting either
/// wrong means the desktop treats our records as new objects and the phone
/// duplicates every space on first sync.
///
/// Keeping the map here rather than adding a field to `Space` and `Tab` means
/// the browser model stays unaware of sync, and a build without sync is
/// unchanged.
struct SyncIdentityMap: Codable, Equatable, Sendable {
    private var localToRemote: [String: String] = [:]
    private var remoteToLocal: [String: String] = [:]

    init() {}

    // MARK: Spaces

    /// The desktop form of a space id: lowercase, in braces.
    static func desktopSpaceID(for uuid: UUID) -> String {
        "{" + uuid.uuidString.lowercased() + "}"
    }

    /// A desktop space id parses straight back to a `UUID` once the braces are
    /// off, so both sides can agree on identity without a lookup.
    static func uuid(fromDesktopSpaceID id: String) -> UUID? {
        var trimmed = id
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return UUID(uuidString: trimmed)
    }

    // MARK: Tabs

    /// Desktop's `ZenWindowSync` tab id generator, reproduced so that records
    /// we create look like records it creates.
    static func newDesktopTabID(now: Date = Date()) -> String {
        "\(Int(now.timeIntervalSince1970 * 1000))-\(Int.random(in: 0...100))"
    }

    // MARK: Mapping

    mutating func remoteID(forLocal local: UUID, makingDefault makeDefault: () -> String)
        -> String
    {
        let key = local.uuidString
        if let existing = localToRemote[key] { return existing }
        let remote = makeDefault()
        localToRemote[key] = remote
        remoteToLocal[remote] = key
        return remote
    }

    func localID(forRemote remote: String) -> UUID? {
        remoteToLocal[remote].flatMap(UUID.init(uuidString:))
    }

    func remoteID(forLocal local: UUID) -> String? {
        localToRemote[local.uuidString]
    }

    mutating func link(local: UUID, remote: String) {
        // A re-link has to clear the old pairing, or a stale remote id keeps
        // resolving to a local object that no longer claims it.
        if let previous = localToRemote[local.uuidString] { remoteToLocal[previous] = nil }
        localToRemote[local.uuidString] = remote
        remoteToLocal[remote] = local.uuidString
    }

    mutating func forget(local: UUID) {
        if let remote = localToRemote.removeValue(forKey: local.uuidString) {
            remoteToLocal[remote] = nil
        }
    }

    mutating func forget(remote: String) {
        if let local = remoteToLocal.removeValue(forKey: remote) {
            localToRemote[local] = nil
        }
    }

    /// Drop pairings for local objects that no longer exist, so the file does
    /// not grow for the life of the install.
    mutating func prune(keepingLocal alive: Set<UUID>) {
        let keep = Set(alive.map(\.uuidString))
        for (local, remote) in localToRemote where !keep.contains(local) {
            localToRemote[local] = nil
            remoteToLocal[remote] = nil
        }
    }
}
