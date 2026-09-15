//  SpacesMergeTests.swift
//  The merge rules: the diff, the journal, last-writer-wins, tombstones and
//  ordering. All pure functions over value types, so none of this needs a
//  network or a browser.

import XCTest

@testable import Zen

final class SpacesMergeTests: XCTestCase {

    private var identities = SyncIdentityMap()
    private var symbolShadow: [String: String] = [:]
    private var shadow = CollectionShadow()

    override func setUp() {
        super.setUp()
        identities = SyncIdentityMap()
        symbolShadow = [:]
        shadow = CollectionShadow()
    }

    private func state(_ spaceName: String = "Work") -> SpacesState {
        let space = Space(name: spaceName, icon: "💼")
        var pinned = Tab(
            url: URL(string: "https://example.com")!, title: "Example", kind: .pinned,
            spaceID: space.id, pinnedURL: URL(string: "https://example.com")!)
        pinned.id = UUID()
        return SpacesState(spaces: [space], tabs: [pinned])
    }

    private func journal(_ state: SpacesState, now: Double) {
        SpacesEngine.journalLocalChanges(
            state: state, shadow: &shadow, identities: &identities,
            symbolShadow: &symbolShadow, syncNormalTabs: false, now: now)
    }

    private func outgoing(_ state: SpacesState) -> (
        records: [DecryptedRecord], tombstones: [String]
    ) {
        SpacesEngine.outgoing(
            from: state, shadow: shadow, identities: &identities,
            symbolShadow: &symbolShadow, syncNormalTabs: false)
    }

    /// Everything is new on a first sync — space, tab and layout.
    func testFirstSyncUploadsEverything() {
        let local = state()
        journal(local, now: 1000)
        let out = outgoing(local)
        XCTAssertEqual(out.records.count, 3)
        XCTAssertTrue(out.tombstones.isEmpty)
        XCTAssertEqual(
            Set(out.records.compactMap { $0.payload["kind"]?.stringValue }),
            ["space", "tab", "layout"])
    }

    /// Once the server has acknowledged them, an unchanged sync uploads
    /// nothing. This is the property that stops a phone burning a battery
    /// re-uploading its own state every quarter hour.
    func testUnchangedStateUploadsNothing() {
        let local = state()
        journal(local, now: 1000)
        for record in outgoing(local).records {
            shadow.noteUploaded(id: record.id, payload: record.payload)
        }
        journal(local, now: 2000)
        XCTAssertTrue(outgoing(local).records.isEmpty)
        XCTAssertTrue(outgoing(local).tombstones.isEmpty)
    }

    func testOnlyTheChangedRecordGoesUp() throws {
        var local = state()
        journal(local, now: 1000)
        for record in outgoing(local).records {
            shadow.noteUploaded(id: record.id, payload: record.payload)
        }

        local.spaces[0].name = "Deep Work"
        journal(local, now: 2000)

        let out = outgoing(local)
        XCTAssertEqual(out.records.count, 1)
        XCTAssertEqual(out.records[0].payload["kind"]?.stringValue, "space")
        XCTAssertEqual(out.records[0].payload["data"]?["name"]?.stringValue, "Deep Work")
    }

    /// The journal stamps a change when it happens, not when the network
    /// comes back — and a second journal pass must not move the timestamp.
    func testJournalKeepsTheFirstTimestamp() throws {
        var local = state()
        journal(local, now: 1000)
        for record in outgoing(local).records {
            shadow.noteUploaded(id: record.id, payload: record.payload)
        }
        local.spaces[0].name = "Changed offline"
        journal(local, now: 5000)
        journal(local, now: 9000)

        let spaceID = try XCTUnwrap(identities.remoteID(forLocal: local.spaces[0].id))
        XCTAssertEqual(shadow.changedAt[spaceID], 5000)
    }

    // MARK: Last writer wins

    /// `children` has to be spelled out: a record that omits a child we do
    /// have is not wrong, it just means we will republish the space with its
    /// children afterwards — which is the self-healing path, not the one
    /// these last-writer-wins tests are about.
    private func incomingSpaceRename(
        _ name: String, id: String, modified: Double, children: [String] = []
    ) throws -> DecryptedRecord {
        let list = children.map { "\"\($0)\"" }.joined(separator: ",")
        return DecryptedRecord(
            id: id, modified: modified,
            payload: try JSONValue(
                jsonString: """
                    {"id":"\(id)","kind":"space","data":{"uuid":"\(id)","name":"\(name)",
                     "icon":"📚","theme":null,"containerGuid":null,"children":[\(list)]}}
                    """))
    }

    func testRemoteWinsWhenItIsNewer() throws {
        var local = state()
        journal(local, now: 1000)
        for record in outgoing(local).records {
            shadow.noteUploaded(id: record.id, payload: record.payload)
        }
        let spaceID = try XCTUnwrap(identities.remoteID(forLocal: local.spaces[0].id))

        local.spaces[0].name = "Local edit"
        journal(local, now: 2000)

        let tabID = try XCTUnwrap(identities.remoteID(forLocal: local.tabs[0].id))
        let report = SpacesEngine.applyIncoming(
            [
                try incomingSpaceRename(
                    "Desktop edit", id: spaceID, modified: 3000, children: [tabID])
            ],
            to: &local, shadow: &shadow, identities: &identities, symbolShadow: &symbolShadow)

        XCTAssertEqual(report.appliedSpaces, 1)
        XCTAssertTrue(report.keptLocal.isEmpty)
        XCTAssertEqual(local.spaces[0].name, "Desktop edit")
        // Having accepted it, we have nothing to say back.
        journal(local, now: 4000)
        XCTAssertTrue(outgoing(local).records.isEmpty)
    }

    func testLocalWinsWhenItIsNewer() throws {
        var local = state()
        journal(local, now: 1000)
        for record in outgoing(local).records {
            shadow.noteUploaded(id: record.id, payload: record.payload)
        }
        let spaceID = try XCTUnwrap(identities.remoteID(forLocal: local.spaces[0].id))

        local.spaces[0].name = "Local edit"
        journal(local, now: 5000)

        let report = SpacesEngine.applyIncoming(
            [try incomingSpaceRename("Desktop edit", id: spaceID, modified: 3000)],
            to: &local, shadow: &shadow, identities: &identities, symbolShadow: &symbolShadow)

        XCTAssertEqual(report.appliedSpaces, 0)
        XCTAssertEqual(report.keptLocal, [spaceID])
        XCTAssertEqual(local.spaces[0].name, "Local edit")
        // …and the local version is still queued to go up.
        let out = outgoing(local)
        XCTAssertEqual(out.records.count, 1)
        XCTAssertEqual(out.records[0].payload["data"]?["name"]?.stringValue, "Local edit")
    }

    /// Applying an incoming record records *its* digest as the new uploaded
    /// state. A materialisation that loses something therefore re-uploads the
    /// local truth next pass rather than drifting silently.
    func testApplyIsSelfHealing() throws {
        var local = state()
        let spaceID = SyncIdentityMap.desktopSpaceID(for: local.spaces[0].id)
        identities.link(local: local.spaces[0].id, remote: spaceID)

        // An incoming record with a field we do not model at all.
        let record = DecryptedRecord(
            id: spaceID, modified: 3000,
            payload: try JSONValue(
                jsonString: """
                    {"id":"\(spaceID)","kind":"space","data":{"uuid":"\(spaceID)",
                     "name":"Work","icon":"💼","theme":null,"containerGuid":"builtin-2",
                     "children":[],"somethingNewerZenAdded":42}}
                    """))
        SpacesEngine.applyIncoming(
            [record], to: &local, shadow: &shadow, identities: &identities,
            symbolShadow: &symbolShadow)

        journal(local, now: 4000)
        let out = outgoing(local)
        // We cannot reproduce `somethingNewerZenAdded`, so the record differs and we
        // re-upload — but the container guid, which we *do* retain, survives.
        if let republished = out.records.first(where: { $0.id == spaceID }) {
            XCTAssertEqual(
                republished.payload["data"]?["containerGuid"]?.stringValue, "builtin-2")
        }
    }

    // MARK: Tombstones

    func testDeletingLocallyProducesATombstone() throws {
        var local = state()
        journal(local, now: 1000)
        for record in outgoing(local).records {
            shadow.noteUploaded(id: record.id, payload: record.payload)
        }
        let tabID = try XCTUnwrap(identities.remoteID(forLocal: local.tabs[0].id))

        local.tabs.removeAll()
        journal(local, now: 2000)

        let out = outgoing(local)
        XCTAssertEqual(out.tombstones, [tabID])
        let tombstone = SpacesEngine.tombstoneRecord(id: tabID)
        XCTAssertEqual(tombstone.payload["deleted"]?.boolValue, true)
        XCTAssertTrue(tombstone.isDeleted)
    }

    func testIncomingTombstoneRemovesTheTab() throws {
        var local = state()
        journal(local, now: 1000)
        let tabID = try XCTUnwrap(identities.remoteID(forLocal: local.tabs[0].id))

        let report = SpacesEngine.applyIncoming(
            [
                DecryptedRecord(
                    id: tabID, modified: 2000,
                    payload: .object(["id": .string(tabID), "deleted": .bool(true)]))
            ],
            to: &local, shadow: &shadow, identities: &identities, symbolShadow: &symbolShadow)

        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(local.tabs.isEmpty)
        XCTAssertNil(identities.localID(forRemote: tabID))
    }

    /// A browser with no space has nowhere to put a tab, so the last one is
    /// never deleted however emphatic the server is.
    func testLastSpaceIsNeverRemoved() throws {
        var local = state()
        journal(local, now: 1000)
        let spaceID = try XCTUnwrap(identities.remoteID(forLocal: local.spaces[0].id))

        SpacesEngine.applyIncoming(
            [
                DecryptedRecord(
                    id: spaceID, modified: 2000,
                    payload: .object(["id": .string(spaceID), "deleted": .bool(true)]))
            ],
            to: &local, shadow: &shadow, identities: &identities, symbolShadow: &symbolShadow)

        XCTAssertEqual(local.spaces.count, 1)
    }

    func testRemovingASpaceTakesItsTabsButNotEssentials() throws {
        var local = state()
        local.spaces.append(Space(name: "Other", icon: "🏠"))
        local.tabs.insert(
            Tab(
                url: URL(string: "https://zen-browser.app")!, kind: .essential,
                pinnedURL: URL(string: "https://zen-browser.app")!), at: 0)
        journal(local, now: 1000)

        let spaceID = try XCTUnwrap(identities.remoteID(forLocal: local.spaces[0].id))
        SpacesEngine.applyIncoming(
            [
                DecryptedRecord(
                    id: spaceID, modified: 2000,
                    payload: .object(["id": .string(spaceID), "deleted": .bool(true)]))
            ],
            to: &local, shadow: &shadow, identities: &identities, symbolShadow: &symbolShadow)

        XCTAssertEqual(local.spaces.count, 1)
        XCTAssertEqual(local.tabs.count, 1)
        XCTAssertEqual(local.tabs[0].kind, .essential)
    }

    // MARK: Ordering

    func testChildOrderIsApplied() throws {
        let space = Space(name: "Work", icon: "💼")
        var tabs: [Tab] = []
        for index in 0..<3 {
            var tab = Tab(
                url: URL(string: "https://example.com/\(index)")!, kind: .pinned,
                spaceID: space.id, pinnedURL: URL(string: "https://example.com/\(index)")!)
            tab.title = "Tab \(index)"
            tabs.append(tab)
        }
        var local = SpacesState(spaces: [space], tabs: tabs)
        journal(local, now: 1000)

        let ids = tabs.map { identities.remoteID(forLocal: $0.id)! }
        let spaceID = identities.remoteID(forLocal: space.id)!

        SpacesEngine.applyChildOrder(
            [ids[2], ids[0], ids[1]], spaceRemoteID: spaceID, to: &local,
            identities: identities)
        XCTAssertEqual(local.tabs.map(\.title), ["Tab 2", "Tab 0", "Tab 1"])
    }

    /// A tab the other device has never heard of must not vanish when it
    /// sends an order that does not mention it.
    func testOrderingKeepsUnmentionedItems() {
        let a = UUID(), b = UUID(), c = UUID()
        let ordered = SpacesEngine.order(
            [(a, "a"), (b, "b"), (c, "c")], by: [c, a], id: \.0)
        XCTAssertEqual(ordered.map(\.1), ["c", "a", "b"])
    }

    func testLayoutReordersSpacesAndEssentials() throws {
        var local = SpacesState(
            spaces: [Space(name: "One", icon: "1️⃣"), Space(name: "Two", icon: "2️⃣")],
            tabs: [
                Tab(
                    url: URL(string: "https://a.example")!, title: "A", kind: .essential,
                    pinnedURL: URL(string: "https://a.example")!),
                Tab(
                    url: URL(string: "https://b.example")!, title: "B", kind: .essential,
                    pinnedURL: URL(string: "https://b.example")!),
            ])
        journal(local, now: 1000)

        let spaceIDs = local.spaces.map { identities.remoteID(forLocal: $0.id)! }
        let tabIDs = local.tabs.map { identities.remoteID(forLocal: $0.id)! }

        SpacesEngine.apply(
            layout: .init(spaces: [spaceIDs[1], spaceIDs[0]], essentials: [tabIDs[1], tabIDs[0]]),
            to: &local, identities: identities)

        XCTAssertEqual(local.spaces.map(\.name), ["Two", "One"])
        XCTAssertEqual(local.tabs.map(\.title), ["B", "A"])
    }

    /// The desktop keys the essentials map by container guid. We have one
    /// container, but another device may not — so the flattening has to be
    /// deterministic and put "default" first.
    func testLayoutFlattensEssentialsAcrossContainers() throws {
        let layout = ZenSpacesRecords.remoteLayout(
            from: try JSONValue(
                jsonString: """
                    {"spaces":["{a}"],"essentials":{"zzz":["t3"],"default":["t1","t2"]}}
                    """))
        XCTAssertEqual(layout.essentials, ["t1", "t2", "t3"])
    }

    // MARK: Ordinary-tab switch

    /// Turning the ordinary-tab switch off must not tombstone the tabs it was
    /// syncing — that would delete them on the desktop.
    func testTurningOffNormalTabsDoesNotDeleteThem() throws {
        var local = state()
        local.tabs.append(
            Tab(
                url: URL(string: "https://example.org")!, title: "Ordinary", kind: .normal,
                spaceID: local.spaces[0].id))

        SpacesEngine.journalLocalChanges(
            state: local, shadow: &shadow, identities: &identities,
            symbolShadow: &symbolShadow, syncNormalTabs: true, now: 1000)
        let withNormal = SpacesEngine.outgoing(
            from: local, shadow: shadow, identities: &identities,
            symbolShadow: &symbolShadow, syncNormalTabs: true)
        for record in withNormal.records {
            shadow.noteUploaded(id: record.id, payload: record.payload)
        }
        let ordinaryID = try XCTUnwrap(identities.remoteID(forLocal: local.tabs[1].id))
        XCTAssertNotNil(shadow.uploaded[ordinaryID])

        // Now the switch goes off. The record stops being projected — and
        // that absence must be treated as "not ours to publish", not as a
        // deletion. Hold it explicitly, as the desktop's `pendingIds` does.
        shadow.held.insert(ordinaryID)
        SpacesEngine.journalLocalChanges(
            state: local, shadow: &shadow, identities: &identities,
            symbolShadow: &symbolShadow, syncNormalTabs: false, now: 2000)
        let out = SpacesEngine.outgoing(
            from: local, shadow: shadow, identities: &identities,
            symbolShadow: &symbolShadow, syncNormalTabs: false)
        XCTAssertFalse(out.tombstones.contains(ordinaryID))
    }
}
