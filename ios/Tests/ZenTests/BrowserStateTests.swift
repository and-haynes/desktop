//  BrowserStateTests.swift
//  Tab and space model operations: move, pin, essential, and what closing a
//  tab selects next.

import XCTest

@testable import Zen

@MainActor
final class BrowserStateTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A state backed entirely by temp files, so tests never touch the real
    /// Application Support directory or each other.
    private func makeState(restore: Bool = false) -> BrowserState {
        BrowserState(
            session: SessionStore(
                file: JSONFileStore<SessionSnapshot>(name: "session.json", directory: directory),
                debounceInterval: 60),
            history: HistoryStore(
                file: JSONFileStore<[HistoryEntry]>(name: "history.json", directory: directory)),
            bookmarks: BookmarkStore(
                file: JSONFileStore<[Bookmark]>(name: "bookmarks.json", directory: directory)),
            restore: restore)
    }

    private func url(_ n: Int) -> URL { URL(string: "https://site\(n).example")! }

    // MARK: First run

    func testFirstRunSeedsSpacesAndATab() {
        let state = makeState()
        XCTAssertFalse(state.spaces.isEmpty)
        XCTAssertNotNil(state.activeSpaceID)
        XCTAssertNotNil(state.activeTab)
        XCTAssertFalse(state.essentials.isEmpty)
    }

    func testMenuKeepsItsTabAndBlocksOtherSheetsThroughDismissal() throws {
        let state = makeState()
        let tab = try XCTUnwrap(state.newTab(url: url(1)))
        state.openBrowserMenu(tabID: tab.id)
        let request = try XCTUnwrap(state.browserMenu)
        XCTAssertTrue(state.isBlockingSheetPresented)
        _ = state.newTab(url: url(2))
        state.openBrowserMenu()
        XCTAssertEqual(state.browserMenu?.id, request.id, "A second tap must not replace an open menu")
        XCTAssertEqual(state.browserMenu?.tabID, tab.id)
        state.browserMenu = nil
        XCTAssertTrue(state.isBlockingSheetPresented, "Dismissal is still in progress")
        state.isBrowserMenuActive = false
        XCTAssertFalse(state.isBlockingSheetPresented)
    }

    func testBothMenuActionsReachThePresenter() {
        let state = makeState()
        var presentations = 0
        let context = BarActionContext(showActionMenu: { presentations += 1 })
        BarActionRunner.perform(.actionMenu, state: state, context: context)
        BarActionRunner.perform(.overflowMenu, state: state, context: context)
        XCTAssertEqual(presentations, 2)
    }

    // MARK: Sections

    func testTabsAreGroupedIntoThreeTiers() {
        let state = makeState()
        let space = state.activeSpaceID!
        XCTAssertTrue(state.essentials.allSatisfy { $0.kind == .essential })
        XCTAssertTrue(state.pinnedTabs.allSatisfy { $0.kind == .pinned && $0.spaceID == space })
        XCTAssertTrue(state.normalTabs.allSatisfy { $0.kind == .normal && $0.spaceID == space })
    }

    /// Essentials are global: they appear from every space.
    func testEssentialsAreVisibleFromEverySpace() {
        let state = makeState()
        let before = state.essentials.map(\.id)
        state.addSpace(
            name: "Other", icon: "star.fill", isSymbol: true, theme: .default)
        XCTAssertEqual(state.essentials.map(\.id), before)
    }

    func testNormalTabsAreScopedToTheirSpace() {
        let state = makeState()
        let first = state.activeSpaceID!
        let firstCount = state.normalTabs.count
        let second = state.addSpace(name: "Other", icon: "star.fill", isSymbol: true, theme: .default)

        // addSpace opens a fresh tab in the new space.
        XCTAssertEqual(state.normalTabs.count, 1)
        state.switchSpace(to: first)
        XCTAssertEqual(state.normalTabs.count, firstCount)
        XCTAssertFalse(state.normalTabs.contains { $0.spaceID == second.id })
    }

    // MARK: Pin / essential

    func testPinningMovesATabIntoThePinnedSection() {
        let state = makeState()
        let tab = state.newTab(url: url(1))!
        XCTAssertEqual(state.tab(id: tab.id)?.kind, .normal)

        state.togglePinned(tab.id)
        XCTAssertEqual(state.tab(id: tab.id)?.kind, .pinned)
        XCTAssertTrue(state.pinnedTabs.contains { $0.id == tab.id })
        XCTAssertFalse(state.normalTabs.contains { $0.id == tab.id })
        // Pinning records the URL to reset to.
        XCTAssertEqual(state.tab(id: tab.id)?.pinnedURL, url(1))
    }

    func testUnpinningClearsThePinnedURL() {
        let state = makeState()
        let tab = state.newTab(url: url(1))!
        state.togglePinned(tab.id)
        state.togglePinned(tab.id)
        XCTAssertEqual(state.tab(id: tab.id)?.kind, .normal)
        XCTAssertNil(state.tab(id: tab.id)?.pinnedURL)
    }

    func testMakingATabEssentialDetachesItFromNoSpace() {
        let state = makeState()
        let tab = state.newTab(url: url(2))!
        state.toggleEssential(tab.id)
        XCTAssertEqual(state.tab(id: tab.id)?.kind, .essential)
        XCTAssertTrue(state.essentials.contains { $0.id == tab.id })
        XCTAssertFalse(state.normalTabs.contains { $0.id == tab.id })
    }

    func testDemotingAnEssentialReturnsItToASpace() {
        let state = makeState()
        let tab = state.newTab(url: url(2))!
        let space = state.activeSpaceID!
        state.toggleEssential(tab.id)
        state.toggleEssential(tab.id)
        XCTAssertEqual(state.tab(id: tab.id)?.kind, .normal)
        XCTAssertEqual(state.tab(id: tab.id)?.spaceID, space)
        XCTAssertTrue(state.normalTabs.contains { $0.id == tab.id })
    }

    func testSettingTheSameKindIsANoOp() {
        let state = makeState()
        let tab = state.newTab(url: url(1))!
        let before = state.tabs.map(\.id)
        state.setKind(.normal, for: tab.id)
        XCTAssertEqual(state.tabs.map(\.id), before)
    }

    // MARK: Reordering

    func testMovingReordersOnlyWithinItsSection() {
        let state = makeState()
        let space = state.activeSpaceID!
        let a = state.newTab(url: url(1))!
        let b = state.newTab(url: url(2))!
        let c = state.newTab(url: url(3))!
        let essentialsBefore = state.essentials.map(\.id)

        let normals = state.normalTabs.map(\.id)
        let indexOfA = normals.firstIndex(of: a.id)!
        XCTAssertLessThan(indexOfA, normals.firstIndex(of: b.id)!)

        // Move `c` to the front of the normal section.
        state.moveTab(c.id, toOffset: 0, kind: .normal, spaceID: space)
        XCTAssertEqual(state.normalTabs.first?.id, c.id)
        // Essentials are untouched.
        XCTAssertEqual(state.essentials.map(\.id), essentialsBefore)
    }

    func testMoveWithIndexSetMatchesSwiftUIOnMove() {
        let state = makeState()
        let space = state.activeSpaceID!
        _ = state.newTab(url: url(1))
        _ = state.newTab(url: url(2))
        let before = state.normalTabs.map(\.id)
        guard before.count >= 2 else { return XCTFail("need two tabs") }

        state.moveTab(kind: .normal, spaceID: space, from: IndexSet(integer: 0), to: before.count)
        let after = state.normalTabs.map(\.id)
        XCTAssertEqual(after.last, before.first)
        XCTAssertEqual(Set(after), Set(before))
    }

    func testMovingAnUnknownTabIsIgnored() {
        let state = makeState()
        let before = state.tabs.map(\.id)
        state.moveTab(UUID(), toOffset: 0, kind: .normal, spaceID: state.activeSpaceID)
        XCTAssertEqual(state.tabs.map(\.id), before)
    }

    func testEssentialsReorderIndependentlyOfSpaces() {
        let state = makeState()
        let essentials = state.essentials
        guard essentials.count >= 2 else { return XCTFail("need two essentials") }
        state.moveTab(essentials.last!.id, toOffset: 0, kind: .essential, spaceID: nil)
        XCTAssertEqual(state.essentials.first?.id, essentials.last?.id)
    }

    // MARK: Closing

    func testClosingTheActiveTabSelectsTheNeighbourThatSlidIntoItsPlace() {
        let state = makeState()
        state.clearNormalTabs()
        let a = state.newTab(url: url(1))!
        let b = state.newTab(url: url(2))!
        let c = state.newTab(url: url(3))!
        state.select(b.id)
        XCTAssertEqual(state.activeTabID, b.id)

        let selected = state.closeTab(b.id)
        // `c` took b's index, so it becomes active.
        XCTAssertEqual(selected, c.id)
        XCTAssertEqual(state.activeTabID, c.id)
        XCTAssertFalse(state.tabs.contains { $0.id == b.id })
        XCTAssertTrue(state.tabs.contains { $0.id == a.id })
    }

    /// Closing the *last* tab in the list has no successor, so it falls back to
    /// the one before it.
    func testClosingTheLastTabSelectsThePrevious() {
        let state = makeState()
        state.clearNormalTabs()
        let a = state.newTab(url: url(1))!
        let b = state.newTab(url: url(2))!
        state.select(b.id)

        let selected = state.closeTab(b.id)
        XCTAssertEqual(selected, a.id)
        XCTAssertEqual(state.activeTabID, a.id)
    }

    func testClosingAnInactiveTabLeavesSelectionAlone() {
        let state = makeState()
        state.clearNormalTabs()
        let a = state.newTab(url: url(1))!
        let b = state.newTab(url: url(2))!
        state.select(b.id)

        state.closeTab(a.id)
        XCTAssertEqual(state.activeTabID, b.id)
    }

    /// A space is never left without a tab.
    func testClosingTheOnlyTabOpensAFreshOne() {
        let state = makeState()
        state.clearNormalTabs()
        // Remove the pinned fallback too, so there is genuinely nothing left.
        for tab in state.pinnedTabs { state.setKind(.normal, for: tab.id) }
        state.clearNormalTabs()

        let only = state.activeTabID
        XCTAssertNotNil(only)
        let selected = state.closeTab(only!)
        XCTAssertNotNil(selected)
        XCTAssertNotEqual(selected, only)
        XCTAssertNotNil(state.activeTab)
    }

    func testClosingFallsBackToAPinnedTabWhenNoNormalTabsRemain() {
        let state = makeState()
        state.clearNormalTabs()
        let pinned = state.pinnedTabs.last
        let only = state.newTab(url: url(1))!
        // Drop every other normal tab so `only` is alone.
        for tab in state.normalTabs where tab.id != only.id { state.closeTab(tab.id) }
        state.select(only.id)

        let selected = state.closeTab(only.id)
        if let pinned {
            XCTAssertEqual(selected, pinned.id)
        }
    }

    /// Pinned and essential tabs reset rather than close.
    func testClosingAPinnedTabResetsItToItsPinnedURL() {
        let state = makeState()
        let tab = state.newTab(url: url(1))!
        state.togglePinned(tab.id)
        state.updateTab(tab.id) { $0.url = url(99); $0.scrollY = 400 }
        XCTAssertEqual(state.tab(id: tab.id)?.url, url(99))

        state.closeTab(tab.id)
        XCTAssertTrue(state.tabs.contains { $0.id == tab.id }, "pinned tab must survive close")
        XCTAssertEqual(state.tab(id: tab.id)?.url, url(1))
        XCTAssertEqual(state.tab(id: tab.id)?.scrollY, 0)
        XCTAssertFalse(state.tab(id: tab.id)?.isLoaded ?? true)
    }

    func testClosingAnEssentialResetsRatherThanRemoves() {
        let state = makeState()
        let essential = state.essentials.first!
        let original = essential.pinnedURL!
        state.updateTab(essential.id) { $0.url = url(50) }

        state.closeTab(essential.id)
        XCTAssertTrue(state.essentials.contains { $0.id == essential.id })
        XCTAssertEqual(state.tab(id: essential.id)?.url, original)
    }

    func testClearNormalTabsLeavesPinnedAndEssentialsAlone() {
        let state = makeState()
        _ = state.newTab(url: url(1))
        _ = state.newTab(url: url(2))
        let pinnedBefore = state.pinnedTabs.map(\.id)
        let essentialsBefore = state.essentials.map(\.id)

        state.clearNormalTabs()
        XCTAssertEqual(state.pinnedTabs.map(\.id), pinnedBefore)
        XCTAssertEqual(state.essentials.map(\.id), essentialsBefore)
        XCTAssertNotNil(state.activeTab)
    }

    func testClosingAnUnknownTabIsHarmless() {
        let state = makeState()
        let before = state.activeTabID
        XCTAssertEqual(state.closeTab(UUID()), before)
    }

    // MARK: Spaces

    func testSwitchingSpaceRemembersItsSelection() {
        let state = makeState()
        let first = state.activeSpaceID!
        let firstTab = state.activeTabID
        let second = state.addSpace(name: "Second", icon: "star.fill", isSymbol: true, theme: .default)
        let secondTab = state.activeTabID
        XCTAssertNotEqual(firstTab, secondTab)

        state.switchSpace(to: first)
        XCTAssertEqual(state.activeTabID, firstTab)
        state.switchSpace(to: second.id)
        XCTAssertEqual(state.activeTabID, secondTab)
    }

    func testCycleSpaceWrapsAround() {
        let state = makeState()
        while state.spaces.count > 2 { state.removeSpace(state.spaces.last!.id) }
        let ids = state.spaces.map(\.id)
        state.switchSpace(to: ids[0])

        state.cycleSpace(by: 1)
        XCTAssertEqual(state.activeSpaceID, ids[1])
        state.cycleSpace(by: 1)
        XCTAssertEqual(state.activeSpaceID, ids[0], "should wrap")
        state.cycleSpace(by: -1)
        XCTAssertEqual(state.activeSpaceID, ids[1], "should wrap backwards")
    }

    func testCycleSpaceWithOneSpaceIsANoOp() {
        let state = makeState()
        while state.spaces.count > 1 { state.removeSpace(state.spaces.last!.id) }
        let only = state.activeSpaceID
        state.cycleSpace(by: 1)
        XCTAssertEqual(state.activeSpaceID, only)
    }

    func testRemovingASpaceClosesItsTabsButKeepsEssentials() {
        let state = makeState()
        let space = state.addSpace(name: "Doomed", icon: "trash", isSymbol: true, theme: .default)
        _ = state.newTab(url: url(1))
        let essentialsBefore = state.essentials.map(\.id)

        state.removeSpace(space.id)
        XCTAssertFalse(state.spaces.contains { $0.id == space.id })
        XCTAssertFalse(state.tabs.contains { $0.spaceID == space.id && !$0.kind.isGlobal })
        XCTAssertEqual(state.essentials.map(\.id), essentialsBefore)
        XCTAssertNotNil(state.activeSpace)
    }

    func testTheLastSpaceCannotBeRemoved() {
        let state = makeState()
        while state.spaces.count > 1 { state.removeSpace(state.spaces.last!.id) }
        let only = state.spaces[0].id
        state.removeSpace(only)
        XCTAssertEqual(state.spaces.count, 1)
    }

    /// Each space gets its own WKWebsiteDataStore identifier — this is what
    /// isolates cookies between spaces.
    func testEachSpaceHasItsOwnDataStoreIdentifier() {
        let state = makeState()
        let a = state.addSpace(name: "A", icon: "a.circle", isSymbol: true, theme: .default)
        let b = state.addSpace(name: "B", icon: "b.circle", isSymbol: true, theme: .default)
        XCTAssertNotEqual(a.dataStoreID, b.dataStoreID)
        XCTAssertEqual(Set(state.spaces.map(\.dataStoreID)).count, state.spaces.count)
    }

    // MARK: Selection & cycling

    func testSelectingAnEssentialDoesNotChangeSpace() {
        let state = makeState()
        let second = state.addSpace(name: "Second", icon: "star.fill", isSymbol: true, theme: .default)
        let essential = state.essentials.first!

        state.select(essential.id)
        XCTAssertEqual(state.activeSpaceID, second.id, "essentials are global, not a space jump")
        XCTAssertEqual(state.activeTabID, essential.id)
    }

    func testCycleTabWalksEssentialsThenPinnedThenNormal() {
        let state = makeState()
        let space = state.activeSpaceID!
        let ordered = state.essentials.map(\.id) + state.pinnedTabs.map(\.id)
            + state.normalTabs.map(\.id)
        guard ordered.count > 1 else { return XCTFail("need several tabs") }

        state.select(ordered[0])
        state.cycleTab(by: 1)
        XCTAssertEqual(state.activeTabID, ordered[1])
        state.cycleTab(by: -1)
        XCTAssertEqual(state.activeTabID, ordered[0])
        state.cycleTab(by: -1)
        XCTAssertEqual(state.activeTabID, ordered.last, "should wrap")
        XCTAssertEqual(state.activeSpaceID, space)
    }

    // MARK: Glance & split

    func testGlanceTabIsNotInTheSidebarUntilExpanded() {
        let state = makeState()
        state.openGlance(url: url(7))
        let glanceID = state.glanceTabID
        XCTAssertNotNil(glanceID)
        XCTAssertTrue(state.isGlanceOnly(glanceID!))

        state.expandGlance()
        XCTAssertNil(state.glanceTabID)
        XCTAssertEqual(state.activeTabID, glanceID)
        XCTAssertTrue(state.normalTabs.contains { $0.id == glanceID })
    }

    func testClosingAGlanceDiscardsItsTab() {
        let state = makeState()
        let before = state.tabs.count
        state.openGlance(url: url(7))
        state.closeGlance()
        XCTAssertNil(state.glanceTabID)
        XCTAssertEqual(state.tabs.count, before)
    }

    func testToggleSplitPicksAPartnerAndToggles() {
        let state = makeState()
        _ = state.newTab(url: url(1))
        XCTAssertFalse(state.isSplitActive)

        state.toggleSplit()
        XCTAssertTrue(state.isSplitActive)
        XCTAssertNotEqual(state.splitSecondaryTabID, state.activeTabID)

        state.toggleSplit()
        XCTAssertFalse(state.isSplitActive)
    }

    func testClosingASplitPartnerLeavesSplit() {
        let state = makeState()
        let partner = state.newTab(url: url(1), select: false)!
        state.split(with: partner.id)
        XCTAssertTrue(state.isSplitActive)

        state.closeTab(partner.id)
        XCTAssertFalse(state.isSplitActive)
    }

    // MARK: Persistence integration

    func testSnapshotRestoresThroughARealFile() throws {
        let state = makeState()
        let tab = state.newTab(url: url(42))!
        state.togglePinned(tab.id)
        state.settings.searchEngine = .startpage
        state.saveNow()

        let restored = makeState(restore: true)
        XCTAssertEqual(restored.settings.searchEngine, .startpage)
        XCTAssertEqual(restored.tab(id: tab.id)?.kind, .pinned)
        XCTAssertEqual(restored.tab(id: tab.id)?.url, url(42))
        XCTAssertEqual(restored.spaces.map(\.id), state.spaces.map(\.id))
        XCTAssertEqual(restored.activeSpaceID, state.activeSpaceID)
    }

    // MARK: History & bookmarks

    func testHistoryRecordsAndDeduplicates() {
        let state = makeState()
        state.history.record(url: url(1), title: "One")
        state.history.record(url: url(2), title: "Two")
        state.history.record(url: url(1), title: "One Again")

        XCTAssertEqual(state.history.entries.count, 2)
        XCTAssertEqual(state.history.entries.first?.url, url(1), "revisit bumps to the top")
        XCTAssertEqual(state.history.entries.first?.visitCount, 2)
        XCTAssertEqual(state.history.entries.first?.title, "One Again")
    }

    func testHistoryIgnoresNonWebSchemes() {
        let state = makeState()
        state.history.record(url: Tab.newTabURL, title: "New Tab")
        XCTAssertTrue(state.history.entries.isEmpty)
    }

    func testHistorySuggestionsRankHostPrefixMatchesFirst() {
        let state = makeState()
        state.history.record(url: URL(string: "https://example.com")!, title: "Nothing alike")
        state.history.record(url: URL(string: "https://other.com")!, title: "example in title")

        let hits = state.history.suggestions(for: "example")
        XCTAssertEqual(hits.first?.url.host, "example.com")
        XCTAssertEqual(hits.count, 2)
    }

    func testBookmarkToggleIsIdempotentPerURL() {
        let state = makeState()
        XCTAssertFalse(state.bookmarks.isBookmarked(url(1)))
        XCTAssertTrue(state.bookmarks.toggle(url: url(1), title: "One", spaceID: nil))
        XCTAssertTrue(state.bookmarks.isBookmarked(url(1)))
        XCTAssertFalse(state.bookmarks.toggle(url: url(1), title: "One", spaceID: nil))
        XCTAssertFalse(state.bookmarks.isBookmarked(url(1)))
    }

    // MARK: Theme plumbing

    func testSpacePaletteFollowsItsOwnAccent() {
        let state = makeState()
        let a = state.spaces[0]
        let b = state.addSpace(
            name: "Hot", icon: "flame.fill", isSymbol: true,
            theme: ZenGradientGenerator.theme(
                seed: ZenColor(hueDegrees: 15, saturation: 95, lightness: 55)))
        XCTAssertNotEqual(
            a.palette(systemDark: true).primary, b.palette(systemDark: true).primary)
    }

    func testThemeNormalisationKeepsExactlyOnePrimaryAndAtMostThreeDots() {
        var theme = ZenTheme()
        theme.dots = (0..<5).map {
            ZenGradientDot(
                color: ZenColor(hueDegrees: Double($0) * 60, saturation: 90, lightness: 50),
                isPrimary: true)
        }
        theme.normalise()
        XCTAssertEqual(theme.dots.count, ZenTheme.maxDots)
        XCTAssertEqual(theme.dots.filter(\.isPrimary).count, 1)
    }

    func testHarmonyProducesTheDocumentedHueOffsets() {
        let seed = ZenColor(hueDegrees: 100, saturation: 90, lightness: 50)
        let triadic = ZenGradientGenerator.harmonised(primary: seed, harmony: .triadic)
        XCTAssertEqual(triadic.count, 2)
        XCTAssertEqual(triadic[0].hsl.hue, 220, accuracy: 0.6)
        XCTAssertEqual(triadic[1].hsl.hue, 340, accuracy: 0.6)
        XCTAssertTrue(ZenGradientGenerator.harmonised(primary: seed, harmony: .floating).isEmpty)
    }
}
