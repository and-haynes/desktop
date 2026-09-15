//  BookmarksEngine.swift
//  The `bookmarks` collection, at leaf level.
//
//  ## What this does and does not do
//
//  Firefox's bookmark sync is a *tree* merge: five roots, arbitrary nesting,
//  `children` arrays that have to stay consistent with every child's
//  `parentid`, separators, queries, livemarks, and a dupe-matching pass. Zen
//  for iOS has a flat list of bookmarks with no folders at all, so a full tree
//  merge would be inventing structure to throw it away again.
//
//  So: we read every `bookmark` leaf anywhere in the tree and show it in the
//  flat list, and we publish ours into the **mobile** root — the folder the
//  desktop already labels "Mobile Bookmarks", which is exactly what these are.
//  Folders, separators and queries are held, not deleted, and the mobile
//  root's `children` array keeps any child we did not author.
//
//  The consequence, stated plainly because it will be noticed: a bookmark
//  filed into a folder on the desktop appears here *unfiled*, and moving it
//  here does not move it there. Folders are the feature to add if that matters
//  more than having the bookmarks at all.

import Foundation

enum BookmarksEngine {
    static let collection = "bookmarks"

    /// The five well-known roots. Ours go in `mobile`.
    static let mobileRoot = "mobile"
    static let mobileRootTitle = "mobile"

    static let leafType = "bookmark"
    static let folderTypes: Set<String> = ["folder", "livemark", "query", "separator"]

    /// A bookmark's sync guid, derived from its local id so it is stable across
    /// launches without a side table.
    static func guid(for bookmark: Bookmark) -> String {
        SyncGUID.derived(from: bookmark.id.uuidString)
    }

    // MARK: Incoming

    struct ApplyResult: Equatable, Sendable {
        var added: [Bookmark] = []
        var updated: [Bookmark] = []
        var removedIDs: [UUID] = []
        var heldRecords = 0
    }

    /// Fold incoming records into the local flat list.
    static func applyIncoming(
        _ records: [DecryptedRecord], into bookmarks: [Bookmark],
        shadow: inout CollectionShadow, identities: inout SyncIdentityMap
    ) -> ApplyResult {
        var result = ApplyResult()
        var byGUID: [String: Bookmark] = [:]
        for bookmark in bookmarks { byGUID[guid(for: bookmark)] = bookmark }

        for record in records {
            if record.isDeleted {
                if let local = identities.localID(forRemote: record.id) {
                    result.removedIDs.append(local)
                    identities.forget(remote: record.id)
                }
                shadow.held.remove(record.id)
                shadow.noteApplied(id: record.id, payload: nil)
                continue
            }

            let type = record.payload["type"]?.stringValue ?? ""
            guard type == leafType,
                let urlString = record.payload["bmkUri"]?.stringValue,
                let url = URL(string: urlString),
                url.scheme == "http" || url.scheme == "https"
            else {
                // Structure we do not model. Hold it so our projection's
                // silence about it is never read as a deletion.
                shadow.held.insert(record.id)
                shadow.retained[record.id] = record.payload
                shadow.uploaded[record.id] = record.payload.digest
                result.heldRecords += 1
                continue
            }

            let title = record.payload["title"]?.stringValue ?? ""
            let addedAt = record.payload["dateAdded"]?.doubleValue.map {
                // dateAdded is in milliseconds.
                Date(timeIntervalSince1970: $0 / 1000)
            }

            if let localID = identities.localID(forRemote: record.id),
                var existing = bookmarks.first(where: { $0.id == localID })
            {
                if existing.url != url || existing.title != title {
                    existing.url = url
                    existing.title = title
                    result.updated.append(existing)
                }
            } else if let existing = byGUID[record.id] {
                // Same content, different provenance — adopt the pairing
                // instead of creating a duplicate.
                identities.link(local: existing.id, remote: record.id)
            } else {
                var bookmark = Bookmark(url: url, title: title, spaceID: nil)
                if let addedAt { bookmark.createdAt = addedAt }
                identities.link(local: bookmark.id, remote: record.id)
                result.added.append(bookmark)
            }
            shadow.noteApplied(id: record.id, payload: record.payload)
        }
        return result
    }

    // MARK: Outgoing

    /// Our bookmarks plus the mobile root that has to list them.
    static func outgoing(
        bookmarks: [Bookmark], shadow: CollectionShadow, identities: inout SyncIdentityMap
    ) -> (records: [DecryptedRecord], tombstones: [String]) {
        var projection: [String: JSONValue] = [:]
        var children: [String] = []

        for bookmark in bookmarks {
            let id = identities.remoteID(forLocal: bookmark.id) { guid(for: bookmark) }
            children.append(id)
            var payload: [String: JSONValue] = shadow.retained[id]?.objectValue ?? [:]
            payload["id"] = .string(id)
            payload["type"] = .string(leafType)
            payload["title"] = .string(bookmark.title)
            payload["bmkUri"] = .string(bookmark.url.absoluteString)
            payload["parentid"] = payload["parentid"] ?? .string(mobileRoot)
            payload["parentName"] = payload["parentName"] ?? .string(mobileRootTitle)
            payload["dateAdded"] = .number(
                (bookmark.createdAt.timeIntervalSince1970 * 1000).rounded())
            payload["tags"] = payload["tags"] ?? .array([])
            payload["keyword"] = payload["keyword"] ?? .null
            payload["description"] = payload["description"] ?? .null
            payload["loadInSidebar"] = payload["loadInSidebar"] ?? .bool(false)
            projection[id] = .object(payload)
        }

        // Keep any child of the mobile root we did not author — a folder the
        // desktop made there is not ours to unfile.
        let retainedChildren =
            shadow.retained[mobileRoot]?["children"]?.arrayValue?.compactMap(\.stringValue)
            ?? []
        let ours = Set(children)
        children += retainedChildren.filter { !ours.contains($0) }

        projection[mobileRoot] = .object([
            "id": .string(mobileRoot),
            "type": .string("folder"),
            "parentid": .string("places"),
            "parentName": .string(""),
            "title": .string(mobileRootTitle),
            "children": .array(children.map { .string($0) }),
        ])

        var records: [DecryptedRecord] = []
        for (id, payload) in projection.sorted(by: { $0.key < $1.key })
        where shadow.uploaded[id] != payload.digest {
            records.append(DecryptedRecord(id: id, modified: 0, payload: payload))
        }
        let tombstones = shadow.pendingDeletions.keys
            .filter { projection[$0] == nil && !shadow.held.contains($0) }
            .sorted()
        return (records, tombstones)
    }
}
