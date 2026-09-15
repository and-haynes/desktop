//  BrowserLayoutTests.swift
//  The layout cycle and its persistence.
//
//  The cycle order is the thing a user feels: pressing the same control three
//  times must come back where it started, in the documented order. And because
//  the setting rides in the session file, the decoder has to tolerate a file
//  written before the setting existed — otherwise shipping it would wipe
//  everyone's tabs.

import XCTest

@testable import Zen

final class BrowserLayoutTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenLayout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Cycle

    func testDefaultLayoutIsCard() {
        XCTAssertEqual(ZenSettings().layout, .card)
    }

    func testCycleOrderIsCardThenEdgeThenFullScreen() {
        XCTAssertEqual(BrowserLayout.card.next, .edgeToEdge)
        XCTAssertEqual(BrowserLayout.edgeToEdge.next, .fullScreen)
        XCTAssertEqual(BrowserLayout.fullScreen.next, .card)
    }

    func testCycleWrapsAfterThreeSteps() {
        var layout = BrowserLayout.card
        for _ in 0..<3 { layout = layout.next }
        XCTAssertEqual(layout, .card)
    }

    func testCycleVisitsEveryCaseExactlyOnce() {
        var seen: [BrowserLayout] = []
        var layout = BrowserLayout.card
        for _ in 0..<BrowserLayout.allCases.count {
            seen.append(layout)
            layout = layout.next
        }
        XCTAssertEqual(seen, [.card, .edgeToEdge, .fullScreen])
        XCTAssertEqual(Set(seen).count, BrowserLayout.allCases.count)
    }

    /// `next` walks `allCases`, so a case added in the middle must not be able
    /// to silently fall out of the cycle.
    func testEveryCaseIsReachable() {
        var reached: Set<BrowserLayout> = []
        var layout = BrowserLayout.allCases[0]
        for _ in 0..<(BrowserLayout.allCases.count * 2) {
            reached.insert(layout)
            layout = layout.next
        }
        XCTAssertEqual(reached, Set(BrowserLayout.allCases))
    }

    // MARK: Behavioural flags

    func testOnlyCardFramesTheContent() {
        XCTAssertTrue(BrowserLayout.card.framesContent)
        XCTAssertFalse(BrowserLayout.edgeToEdge.framesContent)
        XCTAssertFalse(BrowserLayout.fullScreen.framesContent)
    }

    func testEdgeToEdgeAndFullScreenRunUnderTheStatusBar() {
        XCTAssertFalse(BrowserLayout.card.ignoresTopSafeArea)
        XCTAssertTrue(BrowserLayout.edgeToEdge.ignoresTopSafeArea)
        XCTAssertTrue(BrowserLayout.fullScreen.ignoresTopSafeArea)
    }

    /// Only full screen floats the bar; edge-to-edge keeps it in the flow.
    func testOnlyFullScreenFloatsTheBar() {
        XCTAssertFalse(BrowserLayout.card.barFloats)
        XCTAssertFalse(BrowserLayout.edgeToEdge.barFloats)
        XCTAssertTrue(BrowserLayout.fullScreen.barFloats)
    }

    // MARK: Persistence

    func testLayoutSurvivesASessionRoundTrip() throws {
        let store = SessionStore(
            file: JSONFileStore<SessionSnapshot>(name: "session.json", directory: directory),
            debounceInterval: 0.01)
        let space = Space(name: "Work", icon: "briefcase.fill", isSymbol: true)
        var settings = ZenSettings()
        settings.layout = .fullScreen
        settings.compactModeEnabled = true

        let snapshot = SessionSnapshot(
            spaces: [space], tabs: [], activeSpaceID: space.id,
            activeTabIDBySpace: [:], settings: settings)
        XCTAssertTrue(store.saveNow(snapshot))

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.settings.layout, .fullScreen)
        XCTAssertTrue(loaded.settings.compactModeEnabled)
    }

    func testEveryLayoutRoundTripsThroughJSON() throws {
        for layout in BrowserLayout.allCases {
            var settings = ZenSettings()
            settings.layout = layout
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(ZenSettings.self, from: data)
            XCTAssertEqual(decoded.layout, layout)
        }
    }

    /// A session file written before the layout setting existed must still
    /// decode, picking up the default — not fail and take the tabs with it.
    func testSettingsWrittenBeforeTheLayoutExistedStillDecode() throws {
        let legacy = """
            {
              "searchEngine": "ecosia",
              "compactModeEnabled": true,
              "compactHidesSidebar": false,
              "compactHidesToolbar": true,
              "preferDesktopSite": true,
              "sidebarPinnedOnPad": false
            }
            """
        let decoded = try JSONDecoder().decode(ZenSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.layout, .card, "missing key should fall back to the default")
        XCTAssertEqual(decoded.searchEngine, .ecosia)
        XCTAssertTrue(decoded.compactModeEnabled)
        XCTAssertFalse(decoded.compactHidesSidebar)
        XCTAssertTrue(decoded.preferDesktopSite)
        XCTAssertFalse(decoded.sidebarPinnedOnPad)
    }

    /// The same, one level up: a whole session document from before the setting.
    func testLegacySessionDocumentStillRestores() throws {
        let spaceID = UUID()
        let legacy = """
            {
              "version": 1,
              "spaces": [{
                "id": "\(spaceID.uuidString)",
                "name": "Personal",
                "icon": "house.fill",
                "isSymbol": true,
                "dataStoreID": "\(UUID().uuidString)",
                "theme": { "dots": [], "opacity": 0.5, "texture": 0, "harmony": "floating" }
              }],
              "tabs": [],
              "activeSpaceID": "\(spaceID.uuidString)",
              "activeTabIDBySpace": {},
              "settings": { "searchEngine": "google" },
              "savedAt": "2026-09-14T12:00:00Z"
            }
            """
        let url = directory.appendingPathComponent("session.json")
        try Data(legacy.utf8).write(to: url)

        let store = SessionStore(
            file: JSONFileStore<SessionSnapshot>(name: "session.json", directory: directory))
        let loaded = try XCTUnwrap(store.load(), "a pre-layout session must still restore")
        XCTAssertEqual(loaded.spaces.count, 1)
        XCTAssertEqual(loaded.settings.searchEngine, .google)
        XCTAssertEqual(loaded.settings.layout, .card)
    }

    // MARK: Through BrowserState

    @MainActor
    func testCyclingThroughSettingsPersists() throws {
        let makeState: (Bool) -> BrowserState = { restore in
            BrowserState(
                session: SessionStore(
                    file: JSONFileStore<SessionSnapshot>(
                        name: "session.json", directory: self.directory),
                    debounceInterval: 60),
                history: HistoryStore(
                    file: JSONFileStore<[HistoryEntry]>(
                        name: "history.json", directory: self.directory)),
                bookmarks: BookmarkStore(
                    file: JSONFileStore<[Bookmark]>(
                        name: "bookmarks.json", directory: self.directory)),
                restore: restore)
        }

        let state = makeState(false)
        XCTAssertEqual(state.settings.layout, .card)
        state.settings.layout = state.settings.layout.next
        XCTAssertEqual(state.settings.layout, .edgeToEdge)
        state.settings.layout = state.settings.layout.next
        XCTAssertEqual(state.settings.layout, .fullScreen)
        state.saveNow()

        let restored = makeState(true)
        XCTAssertEqual(restored.settings.layout, .fullScreen)
    }
}
