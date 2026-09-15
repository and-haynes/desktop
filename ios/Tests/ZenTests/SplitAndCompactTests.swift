//  SplitAndCompactTests.swift
//  Per-pane URL bars (#00894) and the scroll-driven compact bar (#00895).

import XCTest

@testable import Zen

@MainActor
final class SplitPaneOmniboxTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenSplit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeState() -> BrowserState {
        BrowserState(
            session: SessionStore(
                file: JSONFileStore<SessionSnapshot>(name: "session.json", directory: directory),
                debounceInterval: 60),
            history: HistoryStore(
                file: JSONFileStore<[HistoryEntry]>(name: "history.json", directory: directory)),
            bookmarks: BookmarkStore(
                file: JSONFileStore<[Bookmark]>(name: "bookmarks.json", directory: directory)),
            restore: false)
    }

    private func url(_ n: Int) -> URL { URL(string: "https://site\(n).example")! }

    func testOmniboxDefaultsToTheActiveTab() {
        let state = makeState()
        let active = state.activeTabID
        state.openOmnibox(for: nil, prefill: "")
        XCTAssertNil(state.omniboxTargetTabID)
        XCTAssertEqual(state.omniboxTargetTab?.id, active)
    }

    /// The whole point: typing in the second pane's bar must not navigate the
    /// first pane.
    func testOmniboxCanTargetASpecificPane() {
        let state = makeState()
        let partner = state.newTab(url: url(1), select: false)!
        state.split(with: partner.id)
        XCTAssertNotEqual(state.activeTabID, partner.id)

        state.openOmnibox(for: partner.id, prefill: "https://site1.example")
        XCTAssertEqual(state.omniboxTargetTab?.id, partner.id)
        XCTAssertNotEqual(state.omniboxTargetTab?.id, state.activeTabID)
        XCTAssertTrue(state.isOmniboxOpen)
        XCTAssertEqual(state.omniboxText, "https://site1.example")
    }

    func testTargetSurvivesTheActiveTabChanging() {
        let state = makeState()
        let partner = state.newTab(url: url(1), select: false)!
        state.openOmnibox(for: partner.id, prefill: "")
        state.select(state.normalTabs.first!.id)
        XCTAssertEqual(state.omniboxTargetTab?.id, partner.id)
    }

    /// A target pointing at a closed tab must fall back rather than resolve to
    /// nothing and drop the navigation on the floor.
    func testTargetForAClosedTabFallsBackToNil() {
        let state = makeState()
        let partner = state.newTab(url: url(1), select: false)!
        state.openOmnibox(for: partner.id, prefill: "")
        state.closeTab(partner.id)
        XCTAssertNil(state.omniboxTargetTab)
    }

    func testClosingTheSplitPartnerLeavesSplit() {
        let state = makeState()
        let partner = state.newTab(url: url(1), select: false)!
        state.split(with: partner.id)
        XCTAssertTrue(state.isSplitActive)
        state.splitSecondaryTabID = nil
        XCTAssertFalse(state.isSplitActive)
    }
}

final class CompactHideDelayTests: XCTestCase {

    func testDefaultDelayIsWithinTheAskedRange() {
        let delay = ZenSettings().compactHideDelay
        XCTAssertGreaterThanOrEqual(delay, 1.5)
        XCTAssertLessThanOrEqual(delay, 2.0)
    }

    func testDelayRoundTripsThroughJSON() throws {
        var settings = ZenSettings()
        settings.compactHideDelay = 3.4
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ZenSettings.self, from: data)
        XCTAssertEqual(decoded.compactHideDelay, 3.4, accuracy: 0.0001)
    }

    /// Settings written before the delay existed must still decode — the same
    /// rule that applies to every new key.
    func testSettingsWrittenBeforeTheDelayStillDecode() throws {
        let legacy = """
            { "searchEngine": "duckduckgo", "compactModeEnabled": true }
            """
        let decoded = try JSONDecoder().decode(ZenSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.compactHideDelay, ZenSettings().compactHideDelay)
        XCTAssertTrue(decoded.compactModeEnabled)
    }
}
