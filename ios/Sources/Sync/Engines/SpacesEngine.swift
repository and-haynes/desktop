//  SpacesEngine.swift
//  The two-way merge for Zen's `spaces` collection.
//
//  The shape of a sync, in order, and why:
//
//  1. **Journal.** Project local state and compare each record's digest with
//     what the server is known to hold. Anything that differs is stamped with
//     the time we first noticed. This runs when the browser changes, not only
//     when the network is available, which is what makes an edit made on a
//     train carry an honest timestamp into the merge an hour later.
//  2. **Apply incoming.** Spaces first, then tabs (a tab names its space),
//     then the layout record, then tombstones. A record whose local
//     counterpart changed *after* the server's copy was written is not
//     applied — last writer wins, and this is the comparison that decides it.
//  3. **Project again and diff.** Ids whose digest still differs go up;
//     ids the server holds that we no longer have become tombstones — unless
//     they are *held*, which is the whole reason folders and split groups
//     survive a phone.
//
//  Step 2 storing the *incoming* digest as the new uploaded state is what
//  makes the merge self-healing: a faithful materialisation re-projects to the
//  same digest and uploads nothing, while a lossy one re-uploads the local
//  truth on the next pass instead of silently drifting.

import Foundation

/// The slice of the browser the spaces engine owns. A plain value so the merge
/// can be tested without a `BrowserState` or a main actor.
struct SpacesState: Equatable, Sendable {
    var spaces: [Space] = []
    var tabs: [Tab] = []
}

struct SpacesApplyReport: Equatable, Sendable {
    var appliedSpaces = 0
    var appliedTabs = 0
    var removed = 0
    var heldForeignRecords = 0
    /// Ids the incoming copy lost to a newer local change.
    var keptLocal: [String] = []

    var isEmpty: Bool {
        appliedSpaces == 0 && appliedTabs == 0 && removed == 0
    }
}

enum SpacesEngine {

    static let collection = "spaces"

    // MARK: 1 — the change journal

    /// Stamp every id whose local projection no longer matches what the server
    /// holds, and note anything that disappeared locally as a pending
    /// deletion. Idempotent: an id already stamped keeps its original time,
    /// because that is when the change actually happened.
    static func journalLocalChanges(
        state: SpacesState, shadow: inout CollectionShadow,
        identities: inout SyncIdentityMap, symbolShadow: inout [String: String],
        syncNormalTabs: Bool, now: Double = Date().timeIntervalSince1970
    ) {
        let projection = ZenSpacesRecords.project(
            spaces: state.spaces, tabs: state.tabs, identities: &identities,
            retained: shadow.retained, symbolShadow: &symbolShadow,
            syncNormalTabs: syncNormalTabs)

        for (id, payload) in projection where shadow.uploaded[id] != payload.digest {
            if shadow.changedAt[id] == nil { shadow.changedAt[id] = now }
            shadow.pendingDeletions[id] = nil
        }
        for id in shadow.uploaded.keys
        where projection[id] == nil && !shadow.held.contains(id) {
            if shadow.pendingDeletions[id] == nil { shadow.pendingDeletions[id] = now }
            shadow.changedAt[id] = nil
        }
    }

    // MARK: 2 — applying what came down

    @discardableResult
    static func applyIncoming(
        _ records: [DecryptedRecord], to state: inout SpacesState,
        shadow: inout CollectionShadow, identities: inout SyncIdentityMap,
        symbolShadow: inout [String: String]
    ) -> SpacesApplyReport {
        var report = SpacesApplyReport()

        var spaces: [DecryptedRecord] = []
        var tabs: [DecryptedRecord] = []
        var layout: DecryptedRecord?
        var tombstones: [DecryptedRecord] = []

        for record in records {
            if record.isDeleted {
                tombstones.append(record)
                continue
            }
            guard let kind = record.kind.flatMap(ZenSpacesRecordKind.init(rawValue:)),
                kind.isModelled
            else {
                // A container, a folder, a split — or a kind a newer Zen
                // invented. Hold it: it is not ours to delete, and its
                // absence from our projection must not read as a deletion.
                shadow.held.insert(record.id)
                shadow.retained[record.id] = record.payload
                shadow.uploaded[record.id] = record.payload.digest
                report.heldForeignRecords += 1
                continue
            }
            switch kind {
            case .space: spaces.append(record)
            case .tab: tabs.append(record)
            case .layout: layout = record
            default: break
            }
        }

        // Spaces before tabs: a tab record names the space it belongs to.
        for record in spaces {
            guard survivesLastWriterWins(record, shadow: shadow, report: &report) else { continue }
            if apply(
                space: record, to: &state, identities: &identities, symbolShadow: &symbolShadow)
            {
                report.appliedSpaces += 1
            }
            shadow.noteApplied(id: record.id, payload: record.payload)
        }

        for record in tabs {
            guard survivesLastWriterWins(record, shadow: shadow, report: &report) else { continue }
            if apply(tab: record, to: &state, identities: &identities) {
                report.appliedTabs += 1
            }
            shadow.noteApplied(id: record.id, payload: record.payload)
        }

        // Ordering last, once every space and tab it refers to exists.
        for record in spaces {
            guard shadow.changedAt[record.id] == nil, let data = record.data else { continue }
            applyChildOrder(
                data["children"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                spaceRemoteID: record.id, to: &state, identities: identities)
        }
        if let layout, survivesLastWriterWins(layout, shadow: shadow, report: &report),
            let data = layout.data
        {
            apply(layout: ZenSpacesRecords.remoteLayout(from: data), to: &state,
                  identities: identities)
            shadow.noteApplied(id: layout.id, payload: layout.payload)
        }

        for record in tombstones {
            if remove(remoteID: record.id, from: &state, identities: &identities) {
                report.removed += 1
            }
            shadow.held.remove(record.id)
            shadow.noteApplied(id: record.id, payload: nil)
            symbolShadow[record.id] = nil
        }

        return report
    }

    /// Last-writer-wins. `changedAt` is when *we* diverged; `modified` is when
    /// the server's copy was written. A local change that is newer keeps the
    /// field, stays in the outgoing diff, and goes up in step 3.
    private static func survivesLastWriterWins(
        _ record: DecryptedRecord, shadow: CollectionShadow, report: inout SpacesApplyReport
    ) -> Bool {
        guard let localChange = shadow.changedAt[record.id] else { return true }
        if localChange > record.modified {
            report.keptLocal.append(record.id)
            return false
        }
        return true
    }

    // MARK: Materialising one record

    private static func apply(
        space record: DecryptedRecord, to state: inout SpacesState,
        identities: inout SyncIdentityMap, symbolShadow: inout [String: String]
    ) -> Bool {
        guard let data = record.data,
            let remote = ZenSpacesRecords.remoteSpace(from: data, id: record.id)
        else { return false }

        let localID =
            identities.localID(forRemote: record.id)
            ?? SyncIdentityMap.uuid(fromDesktopSpaceID: record.id)
            ?? UUID()
        identities.link(local: localID, remote: record.id)

        // An icon we ourselves published as a stand-in for an SF Symbol comes
        // back as that symbol; anyone else's emoji stays an emoji.
        var icon = remote.icon ?? ""
        var isSymbol = false
        if let shadowed = symbolShadow[record.id],
            SpaceIconBridge.emoji(forSymbol: shadowed) == remote.icon
        {
            icon = shadowed
            isSymbol = true
        }

        if let index = state.spaces.firstIndex(where: { $0.id == localID }) {
            state.spaces[index].name = remote.name
            if !icon.isEmpty {
                state.spaces[index].icon = icon
                state.spaces[index].isSymbol = isSymbol
            }
            if !remote.theme.isEmpty { state.spaces[index].theme = remote.theme }
        } else {
            state.spaces.append(
                Space(
                    name: remote.name,
                    icon: icon.isEmpty ? "globe" : icon,
                    isSymbol: icon.isEmpty ? true : isSymbol,
                    theme: remote.theme, id: localID))
        }
        return true
    }

    private static func apply(
        tab record: DecryptedRecord, to state: inout SpacesState,
        identities: inout SyncIdentityMap
    ) -> Bool {
        guard let data = record.data,
            let remote = ZenSpacesRecords.remoteTab(from: data, id: record.id)
        else { return false }

        let kind: TabKind = remote.essential ? .essential : (remote.pinned ? .pinned : .normal)

        var spaceID: UUID?
        if !remote.essential {
            spaceID =
                remote.workspaceUUID.flatMap { identities.localID(forRemote: $0) }
                ?? remote.workspaceUUID.flatMap(SyncIdentityMap.uuid(fromDesktopSpaceID:))
            // A tab whose space is not on the server at all still belongs
            // somewhere: losing it would be worse than putting it in the first
            // space, and the next sync moves it if its space turns up.
            if spaceID == nil || !state.spaces.contains(where: { $0.id == spaceID }) {
                spaceID = state.spaces.first?.id
            }
            guard spaceID != nil else { return false }
        }

        if let localID = identities.localID(forRemote: record.id),
            let index = state.tabs.firstIndex(where: { $0.id == localID })
        {
            var tab = state.tabs[index]
            tab.title = remote.title
            tab.kind = kind
            tab.spaceID = kind.isGlobal ? tab.spaceID : spaceID
            if kind.resetsOnClose {
                // The record's url is the *pinned* url; where the tab is right
                // now is this device's business.
                tab.pinnedURL = remote.url
                if tab.url != remote.url && !tab.isLoaded { tab.url = remote.url }
            } else {
                tab.url = remote.url
                tab.pinnedURL = nil
            }
            state.tabs[index] = tab
            return true
        }

        var tab = Tab(
            url: remote.url, title: remote.title, kind: kind,
            spaceID: kind.isGlobal ? nil : spaceID,
            pinnedURL: kind.resetsOnClose ? remote.url : nil)
        identities.link(local: tab.id, remote: record.id)
        // Keep the flat array grouped essentials → pinned → normal, which is
        // the order every section view filters out of it.
        tab.isLoaded = false
        state.tabs.insert(tab, at: insertIndex(for: kind, spaceID: tab.spaceID, in: state))
        return true
    }

    private static func insertIndex(for kind: TabKind, spaceID: UUID?, in state: SpacesState)
        -> Int
    {
        if let last = state.tabs.lastIndex(where: {
            $0.kind == kind && (kind.isGlobal || $0.spaceID == spaceID)
        }) { return last + 1 }
        switch kind {
        case .essential:
            return state.tabs.firstIndex { $0.kind != .essential } ?? state.tabs.count
        case .pinned:
            return state.tabs.firstIndex { $0.kind == .normal } ?? state.tabs.count
        case .normal:
            return state.tabs.count
        }
    }

    @discardableResult
    private static func remove(
        remoteID: String, from state: inout SpacesState, identities: inout SyncIdentityMap
    ) -> Bool {
        guard let localID = identities.localID(forRemote: remoteID) else { return false }
        identities.forget(remote: remoteID)

        if let index = state.tabs.firstIndex(where: { $0.id == localID }) {
            state.tabs.remove(at: index)
            return true
        }
        // The last space is never removed: a browser with no space has
        // nowhere to put a tab.
        if let index = state.spaces.firstIndex(where: { $0.id == localID }),
            state.spaces.count > 1
        {
            state.tabs.removeAll { $0.spaceID == localID && !$0.kind.isGlobal }
            state.spaces.remove(at: index)
            return true
        }
        return false
    }

    // MARK: Ordering

    /// Put a space's pinned (and, when enabled, normal) tabs into the order the
    /// record gives, leaving anything the record does not mention where it is.
    static func applyChildOrder(
        _ children: [String], spaceRemoteID: String, to state: inout SpacesState,
        identities: SyncIdentityMap
    ) {
        guard !children.isEmpty,
            let spaceID = identities.localID(forRemote: spaceRemoteID)
                ?? SyncIdentityMap.uuid(fromDesktopSpaceID: spaceRemoteID)
        else { return }

        let wanted = children.compactMap { identities.localID(forRemote: $0) }
        for kind in [TabKind.pinned, TabKind.normal] {
            reorderSection(
                in: &state, kind: kind, spaceID: spaceID, preferredOrder: wanted)
        }
    }

    static func apply(
        layout: ZenSpacesRecords.RemoteLayout, to state: inout SpacesState,
        identities: SyncIdentityMap
    ) {
        // Space order.
        let wanted = layout.spaces.compactMap {
            identities.localID(forRemote: $0) ?? SyncIdentityMap.uuid(fromDesktopSpaceID: $0)
        }
        if !wanted.isEmpty {
            state.spaces = order(state.spaces, by: wanted, id: \.id)
        }
        // Essentials order.
        let essentials = layout.essentials.compactMap { identities.localID(forRemote: $0) }
        if !essentials.isEmpty {
            reorderSection(in: &state, kind: .essential, spaceID: nil, preferredOrder: essentials)
        }
    }

    /// Rewrite one section of the flat tab array in the given order. Slots
    /// belonging to other sections are untouched, so the array stays grouped.
    private static func reorderSection(
        in state: inout SpacesState, kind: TabKind, spaceID: UUID?, preferredOrder: [UUID]
    ) {
        let slots = state.tabs.indices.filter {
            state.tabs[$0].kind == kind && (kind.isGlobal || state.tabs[$0].spaceID == spaceID)
        }
        guard slots.count > 1 else { return }
        let section = slots.map { state.tabs[$0] }
        let ordered = order(section, by: preferredOrder, id: \.id)
        for (slot, tab) in zip(slots, ordered) { state.tabs[slot] = tab }
    }

    /// Stable reorder: everything named, in the order named, then everything
    /// else in its existing relative order. Not a filter — an item the other
    /// device has not heard of must not vanish.
    static func order<T>(_ items: [T], by preferred: [UUID], id: (T) -> UUID) -> [T] {
        var remaining = items
        var out: [T] = []
        for wanted in preferred {
            if let index = remaining.firstIndex(where: { id($0) == wanted }) {
                out.append(remaining.remove(at: index))
            }
        }
        return out + remaining
    }

    // MARK: 3 — what goes up

    /// The outgoing diff: records whose digest differs from the server's copy,
    /// plus tombstones for what we deleted. `held` ids are never tombstoned.
    static func outgoing(
        from state: SpacesState, shadow: CollectionShadow,
        identities: inout SyncIdentityMap, symbolShadow: inout [String: String],
        syncNormalTabs: Bool
    ) -> (records: [DecryptedRecord], tombstones: [String]) {
        let projection = ZenSpacesRecords.project(
            spaces: state.spaces, tabs: state.tabs, identities: &identities,
            retained: shadow.retained, symbolShadow: &symbolShadow,
            syncNormalTabs: syncNormalTabs)

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

    /// A tombstone is an ordinary record whose payload says so.
    static func tombstoneRecord(id: String) -> DecryptedRecord {
        DecryptedRecord(
            id: id, modified: 0,
            payload: .object(["id": .string(id), "deleted": .bool(true)]))
    }
}
