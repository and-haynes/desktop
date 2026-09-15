//  ZenSpacesRecordTests.swift
//  Zen space records ↔ the local model.
//
//  The desktop-shaped JSON in these tests is written by hand from
//  `ZenSpacesSyncModel.projections()` rather than captured from a running
//  browser, so the field names and shapes here are the assertion: if the
//  schema in the source changes, this is what should fail.

import XCTest

@testable import Zen

final class ZenSpacesRecordTests: XCTestCase {

    private var identities = SyncIdentityMap()
    private var symbolShadow: [String: String] = [:]

    override func setUp() {
        super.setUp()
        identities = SyncIdentityMap()
        symbolShadow = [:]
    }

    // MARK: Identifiers

    /// A Gecko `nsIUUIDGenerator` uuid keeps its braces when stringified, and
    /// Zen's space uuids are exactly that. Dropping them makes every space
    /// look new to the desktop.
    func testSpaceIDsAreBraceWrappedAndLowercase() {
        let uuid = UUID(uuidString: "5F8C2E1A-4B3D-4C7E-9A1F-0123456789AB")!
        let id = SyncIdentityMap.desktopSpaceID(for: uuid)
        XCTAssertEqual(id, "{5f8c2e1a-4b3d-4c7e-9a1f-0123456789ab}")
        XCTAssertEqual(SyncIdentityMap.uuid(fromDesktopSpaceID: id), uuid)
        // And a bare uuid still parses, because not every producer is Gecko.
        XCTAssertEqual(
            SyncIdentityMap.uuid(fromDesktopSpaceID: "5f8c2e1a-4b3d-4c7e-9a1f-0123456789ab"),
            uuid)
        XCTAssertNil(SyncIdentityMap.uuid(fromDesktopSpaceID: "1757894400000-42"))
    }

    /// `ZenWindowSync`'s tab ids are `${Date.now()}-${0..100}` — not UUIDs, so
    /// they can only live in the identity map.
    func testTabIDsLookLikeDesktopTabIDs() {
        let id = SyncIdentityMap.newDesktopTabID(
            now: Date(timeIntervalSince1970: 1_757_894_400))
        let parts = id.split(separator: "-")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], "1757894400000")
        XCTAssertNotNil(Int(parts[1]))
        XCTAssertTrue((0...100).contains(Int(parts[1])!))
    }

    func testIdentityMapRelinkClearsThePreviousPairing() {
        var map = SyncIdentityMap()
        let local = UUID()
        map.link(local: local, remote: "old")
        map.link(local: local, remote: "new")
        XCTAssertNil(map.localID(forRemote: "old"))
        XCTAssertEqual(map.localID(forRemote: "new"), local)
        XCTAssertEqual(map.remoteID(forLocal: local), "new")
    }

    func testIdentityMapPrunesDeadLocals() {
        var map = SyncIdentityMap()
        let kept = UUID()
        let dropped = UUID()
        map.link(local: kept, remote: "a")
        map.link(local: dropped, remote: "b")
        map.prune(keepingLocal: [kept])
        XCTAssertEqual(map.localID(forRemote: "a"), kept)
        XCTAssertNil(map.localID(forRemote: "b"))
    }

    // MARK: Projection

    private func sampleState() -> SpacesState {
        let work = Space(
            name: "Work", icon: "briefcase.fill", isSymbol: true,
            theme: ZenGradientGenerator.theme(
                seed: ZenColor(hueDegrees: 200, saturation: 95, lightness: 55),
                harmony: .analogous),
            id: UUID(uuidString: "5F8C2E1A-4B3D-4C7E-9A1F-0123456789AB")!)
        var essential = Tab(
            url: URL(string: "https://zen-browser.app")!, title: "Zen", kind: .essential,
            pinnedURL: URL(string: "https://zen-browser.app")!)
        essential.id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var pinned = Tab(
            url: URL(string: "https://news.ycombinator.com/item?id=1")!, title: "HN",
            kind: .pinned, spaceID: work.id,
            pinnedURL: URL(string: "https://news.ycombinator.com")!)
        pinned.id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        var normal = Tab(
            url: URL(string: "https://example.com")!, title: "Example", kind: .normal,
            spaceID: work.id)
        normal.id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        return SpacesState(spaces: [work], tabs: [essential, pinned, normal])
    }

    private func project(_ state: SpacesState, syncNormalTabs: Bool = false)
        -> [String: JSONValue]
    {
        ZenSpacesRecords.project(
            spaces: state.spaces, tabs: state.tabs, identities: &identities,
            retained: [:], symbolShadow: &symbolShadow, syncNormalTabs: syncNormalTabs)
    }

    func testSpaceRecordHasTheDesktopFields() throws {
        let state = sampleState()
        let records = project(state)
        let spaceID = "{5f8c2e1a-4b3d-4c7e-9a1f-0123456789ab}"
        let record = try XCTUnwrap(records[spaceID])

        XCTAssertEqual(record["id"]?.stringValue, spaceID)
        XCTAssertEqual(record["kind"]?.stringValue, "space")

        let data = try XCTUnwrap(record["data"])
        XCTAssertEqual(
            Set(data.objectValue!.keys),
            ["uuid", "name", "icon", "theme", "containerGuid", "children"])
        XCTAssertEqual(data["uuid"]?.stringValue, spaceID)
        XCTAssertEqual(data["name"]?.stringValue, "Work")
        // An SF Symbol would show on a desktop as the literal text
        // "briefcase.fill"; we publish the nearest emoji instead.
        XCTAssertEqual(data["icon"]?.stringValue, "💼")
        XCTAssertEqual(data["containerGuid"], .null)

        // Children are this space's pinned tabs in strip order; ordinary tabs
        // only when the owner asked for them.
        let children = try XCTUnwrap(data["children"]?.arrayValue).compactMap(\.stringValue)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(
            children[0],
            identities.remoteID(
                forLocal: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!))
    }

    func testTabRecordHasTheDesktopFields() throws {
        let records = project(sampleState())
        let pinnedID = try XCTUnwrap(
            identities.remoteID(forLocal: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!))
        let data = try XCTUnwrap(records[pinnedID]?["data"])

        XCTAssertEqual(
            Set(data.objectValue!.keys),
            [
                "tabId", "url", "title", "icon", "containerGuid", "essential", "pinned",
                "workspaceUuid", "folderId", "staticLabel", "hasStaticIcon",
                "defaultContainer",
            ])
        XCTAssertEqual(data["tabId"]?.stringValue, pinnedID)
        // A pinned tab's identity is frozen at pin time upstream, so the
        // record carries the *pinned* url, not wherever it has navigated.
        XCTAssertEqual(data["url"]?.stringValue, "https://news.ycombinator.com")
        XCTAssertEqual(data["pinned"]?.boolValue, true)
        XCTAssertEqual(data["essential"]?.boolValue, false)
        XCTAssertEqual(
            data["workspaceUuid"]?.stringValue, "{5f8c2e1a-4b3d-4c7e-9a1f-0123456789ab}")
        XCTAssertEqual(data["folderId"], .null)
    }

    func testEssentialHasNoWorkspace() throws {
        let records = project(sampleState())
        let id = try XCTUnwrap(
            identities.remoteID(forLocal: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!))
        let data = try XCTUnwrap(records[id]?["data"])
        XCTAssertEqual(data["essential"]?.boolValue, true)
        XCTAssertEqual(data["pinned"]?.boolValue, true)
        XCTAssertEqual(data["workspaceUuid"], .null)
    }

    func testOrdinaryTabsAreNotProjectedUnlessAsked() throws {
        let state = sampleState()
        let normal = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let without = project(state)
        XCTAssertNil(identities.remoteID(forLocal: normal).flatMap { without[$0] })

        identities = SyncIdentityMap()
        let with = project(state, syncNormalTabs: true)
        let id = try XCTUnwrap(identities.remoteID(forLocal: normal))
        XCTAssertNotNil(with[id])
        XCTAssertEqual(with[id]?["data"]?["pinned"]?.boolValue, false)
        // …and it joins the space's children.
        let children = with["{5f8c2e1a-4b3d-4c7e-9a1f-0123456789ab}"]?["data"]?["children"]?
            .arrayValue?.compactMap(\.stringValue)
        XCTAssertEqual(children?.count, 2)
    }

    func testNewTabPageIsNeverProjected() {
        var state = sampleState()
        state.tabs.append(Tab.newTab(in: state.spaces[0].id))
        let records = project(state, syncNormalTabs: true)
        for record in records.values where record["kind"]?.stringValue == "tab" {
            XCTAssertNotEqual(record["data"]?["url"]?.stringValue, Tab.newTabURL.absoluteString)
        }
    }

    func testLayoutRecordCarriesSpaceAndEssentialOrder() throws {
        var state = sampleState()
        let second = Space(name: "Personal", icon: "🏠")
        state.spaces.append(second)
        let records = project(state)

        let data = try XCTUnwrap(records[ZenSpacesRecords.layoutRecordID]?["data"])
        XCTAssertEqual(records[ZenSpacesRecords.layoutRecordID]?["kind"]?.stringValue, "layout")
        XCTAssertEqual(
            data["spaces"]?.arrayValue?.compactMap(\.stringValue),
            [
                "{5f8c2e1a-4b3d-4c7e-9a1f-0123456789ab}",
                SyncIdentityMap.desktopSpaceID(for: second.id),
            ])
        // Essentials are keyed by container guid; with no container that is
        // upstream's "default" bucket.
        let essentials = try XCTUnwrap(data["essentials"]?.objectValue)
        XCTAssertEqual(Array(essentials.keys), ["default"])
        XCTAssertEqual(essentials["default"]?.arrayValue?.count, 1)
    }

    /// Two projections of unchanged state must be byte-identical, or every
    /// sync uploads everything.
    func testProjectionIsStable() {
        let state = sampleState()
        let first = project(state)
        let second = project(state)
        XCTAssertEqual(first.mapValues(\.digest), second.mapValues(\.digest))
    }

    // MARK: Themes

    func testThemeRoundTrip() throws {
        let theme = ZenGradientGenerator.theme(
            seed: ZenColor(hueDegrees: 265, saturation: 95, lightness: 62), harmony: .triadic)
        let json = ZenThemeBridge.json(from: theme, retained: nil)

        XCTAssertEqual(json["type"]?.stringValue, "gradient")
        XCTAssertEqual(json["opacity"]?.doubleValue, theme.opacity)
        XCTAssertEqual(json["texture"]?.doubleValue, theme.texture)

        let dots = try XCTUnwrap(json["gradientColors"]?.arrayValue)
        XCTAssertEqual(dots.count, theme.dots.count)
        // Upstream's dot shape.
        XCTAssertEqual(dots[0]["c"]?.arrayValue?.count, 3)
        XCTAssertEqual(dots[0]["isCustom"]?.boolValue, false)
        XCTAssertEqual(dots[0]["algorithm"]?.stringValue, "triadic")
        XCTAssertNotNil(dots[0]["lightness"]?.doubleValue)
        XCTAssertNotNil(dots[0]["position"]?["x"]?.doubleValue)

        let parsed = ZenThemeBridge.theme(from: json)
        XCTAssertEqual(parsed.dots.count, theme.dots.count)
        XCTAssertEqual(parsed.harmony, .triadic)
        XCTAssertEqual(parsed.opacity, theme.opacity)
        for (a, b) in zip(parsed.dots, theme.dots) {
            // Colours survive a trip through 8-bit rgb; a hair of rounding is
            // the price of the desktop's own storage format.
            XCTAssertEqual(a.color.r, b.color.r, accuracy: 0.005)
            XCTAssertEqual(a.color.g, b.color.g, accuracy: 0.005)
            XCTAssertEqual(a.color.b, b.color.b, accuracy: 0.005)
            XCTAssertEqual(a.isPrimary, b.isPrimary)
        }
    }

    /// The desktop's dots carry fields we have no concept of. Losing them
    /// would make the desktop re-upload its own theme after every sync.
    func testUnmodelledThemeFieldsSurviveARoundTrip() throws {
        let desktop = try JSONValue(
            jsonString: """
                {"type":"gradient","opacity":0.7,"texture":0.3,
                 "gradientColors":[
                   {"c":[124,72,240],"isCustom":false,"algorithm":"analogous",
                    "isPrimary":true,"lightness":62,"position":{"x":312,"y":118},
                    "type":"explicit-lightness"}]}
                """)
        let theme = ZenThemeBridge.theme(from: desktop)
        let back = ZenThemeBridge.json(from: theme, retained: desktop)

        let dot = try XCTUnwrap(back["gradientColors"]?.arrayValue?.first)
        XCTAssertEqual(dot["type"]?.stringValue, "explicit-lightness")
        XCTAssertEqual(dot["position"]?["x"]?.doubleValue, 312)
        XCTAssertEqual(dot["position"]?["y"]?.doubleValue, 118)
        XCTAssertEqual(dot["c"]?.arrayValue?.compactMap(\.intValue), [124, 72, 240])
        XCTAssertEqual(back["opacity"]?.doubleValue, 0.7)
        XCTAssertEqual(back["texture"]?.doubleValue, 0.3)
    }

    /// A custom dot's colour is a CSS string rather than a triplet.
    func testCustomDotColourString() {
        XCTAssertEqual(
            ZenThemeBridge.color(from: .string("#7c48f0")),
            ZenColor(0x7c, 0x48, 0xf0))
        XCTAssertNil(ZenThemeBridge.color(from: .null))
        XCTAssertNil(ZenThemeBridge.color(from: .array([.number(1)])))
    }

    func testEmptyThemeKeepsWhateverTheDesktopHad() throws {
        let desktop = try JSONValue(jsonString: #"{"type":"gradient","gradientColors":[]}"#)
        XCTAssertEqual(ZenThemeBridge.json(from: .default, retained: desktop), desktop)
        XCTAssertEqual(ZenThemeBridge.json(from: .default, retained: nil), .null)
    }

    /// `calculateInitialPosition` places a dot by hue angle and saturation
    /// radius on a 380px wheel, so the desktop picker opens with the dot where
    /// it would have put it.
    func testDesktopPositionMatchesTheWheelGeometry() throws {
        // Hue 0, full saturation → straight out along +x from the centre.
        let position = ZenThemeBridge.desktopPosition(
            for: ZenColor(hueDegrees: 0, saturation: 100, lightness: 50))
        XCTAssertEqual(position["x"]?.doubleValue, 380)
        XCTAssertEqual(position["y"]?.doubleValue, 190)

        // A grey has no saturation, so it sits at the centre.
        let grey = ZenThemeBridge.desktopPosition(for: ZenColor(128, 128, 128))
        XCTAssertEqual(grey["x"]?.doubleValue, 190)
        XCTAssertEqual(grey["y"]?.doubleValue, 190)
    }

    // MARK: Parsing a desktop-authored record

    func testAppliesADesktopSpaceAndItsTabs() throws {
        var state = SpacesState(spaces: [Space(name: "Personal", icon: "🏠")], tabs: [])
        var shadow = CollectionShadow()

        let spaceID = "{aabbccdd-1122-3344-5566-778899aabbcc}"
        let tabID = "1757894400000-7"
        let records = [
            DecryptedRecord(
                id: spaceID, modified: 100,
                payload: try JSONValue(
                    jsonString: """
                        {"id":"\(spaceID)","kind":"space","data":{
                          "uuid":"\(spaceID)","name":"Reading","icon":"📚","theme":null,
                          "containerGuid":null,"children":["\(tabID)"]}}
                        """)),
            DecryptedRecord(
                id: tabID, modified: 101,
                payload: try JSONValue(
                    jsonString: """
                        {"id":"\(tabID)","kind":"tab","data":{
                          "tabId":"\(tabID)","url":"https://lobste.rs/","title":"Lobsters",
                          "icon":"","containerGuid":null,"essential":false,"pinned":true,
                          "workspaceUuid":"\(spaceID)","folderId":null,"staticLabel":null,
                          "hasStaticIcon":false,"defaultContainer":false}}
                        """)),
        ]

        let report = SpacesEngine.applyIncoming(
            records, to: &state, shadow: &shadow, identities: &identities,
            symbolShadow: &symbolShadow)

        XCTAssertEqual(report.appliedSpaces, 1)
        XCTAssertEqual(report.appliedTabs, 1)
        XCTAssertEqual(state.spaces.count, 2)

        let space = try XCTUnwrap(state.spaces.last)
        XCTAssertEqual(space.name, "Reading")
        XCTAssertEqual(space.icon, "📚")
        XCTAssertFalse(space.isSymbol)
        // The uuid inside the braces *is* our local id, so both ends agree
        // about identity without a lookup.
        XCTAssertEqual(space.id.uuidString.lowercased(), "aabbccdd-1122-3344-5566-778899aabbcc")

        let tab = try XCTUnwrap(state.tabs.first)
        XCTAssertEqual(tab.kind, .pinned)
        XCTAssertEqual(tab.url.absoluteString, "https://lobste.rs/")
        XCTAssertEqual(tab.pinnedURL?.absoluteString, "https://lobste.rs/")
        XCTAssertEqual(tab.spaceID, space.id)
    }

    /// A record kind this build does not model — a folder, a split group, or
    /// something a newer Zen invented — is held, never deleted.
    func testForeignKindsAreHeldNotDropped() throws {
        var state = SpacesState(spaces: [Space(name: "A", icon: "🏠")], tabs: [])
        var shadow = CollectionShadow()
        let record = DecryptedRecord(
            id: "folder-1", modified: 10,
            payload: try JSONValue(
                jsonString: #"{"id":"folder-1","kind":"folder","data":{"name":"Recipes"}}"#))

        let report = SpacesEngine.applyIncoming(
            [record], to: &state, shadow: &shadow, identities: &identities,
            symbolShadow: &symbolShadow)

        XCTAssertEqual(report.heldForeignRecords, 1)
        XCTAssertTrue(shadow.held.contains("folder-1"))
        XCTAssertEqual(shadow.retained["folder-1"], record.payload)

        // …and it never shows up as a tombstone, however long it sits there.
        SpacesEngine.journalLocalChanges(
            state: state, shadow: &shadow, identities: &identities,
            symbolShadow: &symbolShadow, syncNormalTabs: false, now: 1000)
        let outgoing = SpacesEngine.outgoing(
            from: state, shadow: shadow, identities: &identities,
            symbolShadow: &symbolShadow, syncNormalTabs: false)
        XCTAssertFalse(outgoing.tombstones.contains("folder-1"))
    }

    /// An SF Symbol we substituted an emoji for comes back as the symbol; a
    /// desktop-authored emoji stays an emoji.
    func testSymbolShadowSurvivesTheRoundTrip() throws {
        let state = sampleState()
        _ = project(state)
        let spaceID = "{5f8c2e1a-4b3d-4c7e-9a1f-0123456789ab}"
        XCTAssertEqual(symbolShadow[spaceID], "briefcase.fill")

        var fresh = SpacesState(spaces: [], tabs: [])
        var shadow = CollectionShadow()
        let record = DecryptedRecord(
            id: spaceID, modified: 10,
            payload: try JSONValue(
                jsonString: """
                    {"id":"\(spaceID)","kind":"space","data":{"uuid":"\(spaceID)",
                     "name":"Work","icon":"💼","theme":null,"containerGuid":null,
                     "children":[]}}
                    """))
        SpacesEngine.applyIncoming(
            [record], to: &fresh, shadow: &shadow, identities: &identities,
            symbolShadow: &symbolShadow)

        XCTAssertEqual(fresh.spaces.first?.icon, "briefcase.fill")
        XCTAssertEqual(fresh.spaces.first?.isSymbol, true)
    }
}
