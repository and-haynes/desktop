//  NavigationHelperTests.swift
//  The page-step arithmetic and the show/hide machine (#008B9).
//
//  Two separable things, tested separately. The arithmetic is where a page
//  step silently loses content: paging by the scroll view's *bounds* rather
//  than by what is visible scrolls a bar's worth of text behind the chrome on
//  every tap, and nothing on screen says so — you just find you have skipped a
//  paragraph. The state machine is where the buttons steal a gesture or refuse
//  to go away, and it runs on the same injected clock compact mode uses so it
//  is testable in microseconds rather than in multiples of three seconds.

import XCTest

@testable import Zen

@MainActor
final class NavigationHelperTests: XCTestCase {

    /// The same shape as `CompactBarTests.ManualClock`: one pending countdown,
    /// fired by hand, so a test can also assert that nothing fired.
    private final class ManualClock: CompactBarClock {
        private var pending: (@MainActor () -> Void)?
        private(set) var lastDelay: TimeInterval?

        var hasPending: Bool { pending != nil }

        func schedule(after seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
            lastDelay = seconds
            pending = body
        }

        func cancel() { pending = nil }

        @discardableResult
        func fire() -> Bool {
            guard let body = pending else { return false }
            pending = nil
            body()
            return true
        }
    }

    private var clock: ManualClock!
    private var haptics: [HapticEvent] = []

    private func makeHelper(enabled: Bool = true, delay: TimeInterval = 3)
        -> NavigationHelperController
    {
        clock = ManualClock()
        haptics = []
        let helper = NavigationHelperController(clock: clock) { [weak self] event in
            self?.haptics.append(event)
        }
        helper.stillDelay = delay
        helper.isEnabled = enabled
        return helper
    }

    // MARK: The page step

    /// The whole point of the overlap: a step is a screenful *minus* the lines
    /// you were reading, so the tap never loses your place.
    func testAPageStepIsOneScreenfulLessTheOverlap() {
        XCTAssertEqual(PageScroll.stride(viewportHeight: 800), 800 - PageScroll.overlap)
    }

    /// The bug this is here to stop: paging by the bounds would move a bar's
    /// and an island's worth of content behind the chrome on every tap.
    func testTheStepDiscountsTheChromeTheInsetsRepresent() {
        let full = PageScroll.stride(viewportHeight: 800)
        let inset = PageScroll.stride(viewportHeight: 800, topInset: 60, bottomInset: 80)
        XCTAssertEqual(inset, full - 140)
    }

    func testATinyViewportStillStepsForwards() {
        XCTAssertEqual(PageScroll.stride(viewportHeight: 30), PageScroll.minimumStride)
        XCTAssertGreaterThan(PageScroll.stride(viewportHeight: 0, bottomInset: 200), 0)
    }

    func testPagingDownAndBackUpReturnsToWhereYouWere() {
        let down = PageScroll.target(
            .pageDown, from: 0, viewportHeight: 800, contentHeight: 10_000)
        XCTAssertEqual(down, 800 - PageScroll.overlap)
        let up = PageScroll.target(
            .pageUp, from: down, viewportHeight: 800, contentHeight: 10_000)
        XCTAssertEqual(up, 0)
    }

    func testTopAndBottomGoAllTheWay() {
        XCTAssertEqual(
            PageScroll.target(.top, from: 5_000, viewportHeight: 800, contentHeight: 10_000), 0)
        XCTAssertEqual(
            PageScroll.target(.bottom, from: 0, viewportHeight: 800, contentHeight: 10_000),
            9_200)
    }

    /// With a top inset the top of the page is a *negative* offset, which is
    /// the classic off-by-an-inset: scrolling to 0 would leave the page's own
    /// header under the island.
    func testTopWithAnInsetIsAboveZero() {
        XCTAssertEqual(
            PageScroll.target(
                .top, from: 900, viewportHeight: 800, contentHeight: 10_000, topInset: 59),
            -59)
    }

    func testBottomAccountsForTheInsetTheBarTakes() {
        XCTAssertEqual(
            PageScroll.target(
                .bottom, from: 0, viewportHeight: 800, contentHeight: 10_000,
                topInset: 59, bottomInset: 80),
            10_000 - 800 + 80)
    }

    func testAStepIsClampedRatherThanRunningOffEitherEnd() {
        XCTAssertEqual(
            PageScroll.target(.pageUp, from: 10, viewportHeight: 800, contentHeight: 10_000), 0)
        XCTAssertEqual(
            PageScroll.target(
                .pageDown, from: 9_100, viewportHeight: 800, contentHeight: 10_000),
            9_200)
    }

    /// A document shorter than the window has exactly one valid position, and
    /// every button must agree on it — otherwise Page Down on a short page
    /// bounces the view.
    func testAPageShorterThanTheWindowCannotScrollAtAll() {
        for step in PageScrollStep.allCases {
            XCTAssertEqual(
                PageScroll.target(step, from: 0, viewportHeight: 800, contentHeight: 300), 0,
                "\(step) moved a page that has nowhere to go")
        }
    }

    func testTheStackIsOrderedTopToBottom() {
        XCTAssertEqual(PageScrollStep.stacked, [.top, .pageUp, .pageDown, .bottom])
        XCTAssertEqual(Set(PageScrollStep.stacked), Set(PageScrollStep.allCases))
        XCTAssertEqual(PageScrollStep.pageUp.symbol, "chevron.up")
        XCTAssertEqual(PageScrollStep.pageDown.symbol, "chevron.down")
        XCTAssertEqual(PageScrollStep.top.symbol, "arrow.up.to.line")
        XCTAssertEqual(PageScrollStep.bottom.symbol, "arrow.down.to.line")
    }

    // MARK: Show and hide

    func testTheyStartHidden() {
        let helper = makeHelper()
        XCTAssertFalse(helper.isVisible)
        XCTAssertFalse(clock.hasPending, "nothing should be counting down before anything shows")
    }

    func testScrollingBringsThemInAndStillnessTakesThemAway() {
        let helper = makeHelper()
        helper.pageDidScroll()
        XCTAssertTrue(helper.isVisible)
        XCTAssertFalse(clock.hasPending, "the still-timer must not run during a scroll")

        helper.scrollDidEnd()
        XCTAssertTrue(clock.hasPending)
        clock.fire()
        XCTAssertFalse(helper.isVisible)
    }

    func testTheFadeUsesTheCompactStillDelay() {
        _ = makeHelper(delay: 4.5)
        let helper = makeHelper(delay: 4.5)
        helper.pageDidScroll()
        helper.scrollDidEnd()
        XCTAssertEqual(clock.lastDelay, 4.5)
    }

    func testAnAbsurdlyShortDelayIsFloored() {
        let helper = makeHelper(delay: 0)
        helper.pageDidScroll()
        helper.scrollDidEnd()
        XCTAssertGreaterThanOrEqual(clock.lastDelay ?? 0, 0.2)
    }

    /// A long flick is many scroll events; they must not flicker.
    func testALongFlickKeepsThemSteady() {
        let helper = makeHelper()
        for _ in 0..<10 {
            helper.pageDidScroll()
            XCTAssertTrue(helper.isVisible)
            XCTAssertFalse(clock.hasPending)
        }
    }

    func testPagingKeepsThemForAsLongAsYouArePaging() {
        let helper = makeHelper()
        helper.pageDidScroll()
        for _ in 0..<4 {
            helper.stepTapped()
            XCTAssertTrue(helper.isVisible)
            XCTAssertTrue(clock.hasPending, "each tap restarts the countdown")
        }
        clock.fire()
        XCTAssertFalse(helper.isVisible)
    }

    func testEachTapIsFeltOnce() {
        let helper = makeHelper()
        helper.pageDidScroll()
        haptics = []
        helper.stepTapped()
        XCTAssertEqual(haptics, [.navigationStep])
    }

    /// Nothing should buzz for a scroll — the finger is already moving, and
    /// `Haptics` silences the page anyway.
    func testAppearingIsSilent() {
        let helper = makeHelper()
        helper.pageDidScroll()
        helper.scrollDidEnd()
        clock.fire()
        XCTAssertEqual(haptics, [])
    }

    func testTappingThePagePutsThemAwayAtOnce() {
        let helper = makeHelper()
        helper.pageDidScroll()
        helper.pageTapped()
        XCTAssertFalse(helper.isVisible)
        XCTAssertFalse(clock.hasPending)
    }

    /// The page's dismiss-tap is a `simultaneousGesture` over the buttons, so
    /// it fires for a touch on a button too. Whichever order the two arrive
    /// in, the helper has to end up on screen — a button that dismisses itself
    /// is a button you cannot press twice.
    func testAButtonTapIsNotAPageTap() {
        let helper = makeHelper()
        helper.pageDidScroll()

        helper.stepTapped()
        helper.pageTapped()
        XCTAssertTrue(helper.isVisible, "the button's own touch dismissed the helper")

        // And the other delivery order.
        helper.pageTapped()
        helper.stepTapped()
        XCTAssertTrue(helper.isVisible)
    }

    /// Only one page tap is eaten per button tap, or the dismiss would stop
    /// working entirely after the first step.
    func testTheNextPageTapAfterThatStillDismisses() {
        let helper = makeHelper()
        helper.pageDidScroll()
        helper.stepTapped()
        helper.pageTapped()
        helper.pageTapped()
        XCTAssertFalse(helper.isVisible)
    }

    func testAnythingCoveringThePageTakesThemAway() {
        let helper = makeHelper()
        helper.pageDidScroll()
        helper.coveredDidChange(true)
        XCTAssertFalse(helper.isVisible)
        XCTAssertFalse(clock.hasPending)

        // Uncovering does *not* hand them back: there was no scroll, so there
        // is nothing to say you want to page.
        helper.coveredDidChange(false)
        XCTAssertFalse(helper.isVisible)
    }

    // MARK: Off

    func testWithTheHelperOffNothingEverAppears() {
        let helper = makeHelper(enabled: false)
        helper.pageDidScroll()
        helper.scrollDidEnd()
        helper.stepTapped()
        XCTAssertFalse(helper.isVisible)
        XCTAssertFalse(clock.hasPending)
        XCTAssertEqual(haptics, [])
    }

    func testSwitchingItOffTakesThemAwayAtOnceRatherThanOnTheTimer() {
        let helper = makeHelper()
        helper.pageDidScroll()
        XCTAssertTrue(helper.isVisible)
        helper.isEnabled = false
        XCTAssertFalse(helper.isVisible)
        XCTAssertFalse(clock.hasPending)
    }

    // MARK: The side

    /// Automatic is the edge *opposite* the sidebar: the sidebar's own edge
    /// already carries the drawer swipe and the bar's sidebar button.
    func testAutomaticSitsOppositeTheSidebar() {
        var settings = ZenSettings()
        settings.navigationHelperSide = nil

        settings.sidebarEdge = .leading
        XCTAssertEqual(settings.resolvedNavigationHelperSide, .trailing)

        settings.sidebarEdge = .trailing
        XCTAssertEqual(settings.resolvedNavigationHelperSide, .leading)
    }

    func testAnExplicitSideWins() {
        var settings = ZenSettings()
        settings.sidebarEdge = .leading
        settings.navigationHelperSide = .leading
        XCTAssertEqual(settings.resolvedNavigationHelperSide, .leading)
    }

    // MARK: Persistence

    func testTheSettingsSurviveARoundTripAndAnOlderFile() throws {
        var settings = ZenSettings()
        settings.navigationHelperEnabled = true
        settings.navigationHelperSide = .trailing
        let restored = try JSONDecoder().decode(
            ZenSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.navigationHelperEnabled)
        XCTAssertEqual(restored.navigationHelperSide, .trailing)

        let older = try JSONDecoder().decode(
            ZenSettings.self, from: Data(#"{"searchEngine":"google"}"#.utf8))
        XCTAssertFalse(older.navigationHelperEnabled)
        XCTAssertNil(older.navigationHelperSide, "absent must stay Automatic, not become an edge")
    }

    /// nil is a third answer, not a missing one: a round trip that turned
    /// Automatic into an edge would freeze the side the day you moved the
    /// sidebar.
    func testAutomaticSurvivesARoundTrip() throws {
        var settings = ZenSettings()
        settings.navigationHelperSide = nil
        let restored = try JSONDecoder().decode(
            ZenSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertNil(restored.navigationHelperSide)
    }
}
