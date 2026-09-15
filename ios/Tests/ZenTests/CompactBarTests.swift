//  CompactBarTests.swift
//  Compact mode's three states, driven on a clock the test owns (#008AF).
//
//  The countdown is the whole feature, so waiting for it in real time would
//  make this suite slower than every other test put together and flakier than
//  all of them. `ManualClock` stands in for `Task.sleep`: nothing fires until
//  the test says so, which also means a test can assert that something did
//  *not* fire.

import XCTest

@testable import Zen

@MainActor
final class CompactBarTests: XCTestCase {

    /// The injected clock. Holds one pending countdown, exactly as the real
    /// one does — scheduling replaces rather than stacks.
    private final class ManualClock: CompactBarClock {
        private var pending: (@MainActor () -> Void)?
        private(set) var lastDelay: TimeInterval?

        var hasPending: Bool { pending != nil }

        func schedule(after seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
            lastDelay = seconds
            pending = body
        }

        func cancel() {
            pending = nil
        }

        /// What real time would eventually do.
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

    private func makeController(enabled: Bool = true, delay: TimeInterval = 3)
        -> CompactBarController
    {
        clock = ManualClock()
        haptics = []
        let controller = CompactBarController(clock: clock) { [weak self] event in
            self?.haptics.append(event)
        }
        controller.stillDelay = delay
        controller.isEnabled = enabled
        return controller
    }

    // MARK: (a) still → hidden

    /// The whole ask: leave the page alone and the bar goes away entirely,
    /// one step at a time.
    func testAStillPageFallsAllTheWayToHidden() {
        let bar = makeController()
        XCTAssertEqual(bar.phase, .expanded)

        XCTAssertTrue(clock.fire())
        XCTAssertEqual(bar.phase, .pill)

        XCTAssertTrue(clock.fire())
        XCTAssertEqual(bar.phase, .hidden)

        // The floor: nothing is still counting once there is nothing left.
        XCTAssertFalse(clock.hasPending)
    }

    func testTheStillTimerUsesTheSettingsDelay() {
        let bar = makeController(delay: 4.5)
        XCTAssertEqual(clock.lastDelay, 4.5)
        clock.fire()
        XCTAssertEqual(bar.phase, .pill)
        XCTAssertEqual(clock.lastDelay, 4.5)
    }

    /// A delay of zero would make the bar unusable; the floor is deliberate.
    func testAnAbsurdlyShortDelayIsFloored() {
        let bar = makeController(delay: 0)
        XCTAssertGreaterThanOrEqual(clock.lastDelay ?? 0, 0.2)
        XCTAssertEqual(bar.phase, .expanded)
    }

    // MARK: (b) scroll → pill

    func testScrollingBringsBackThePillAndNotTheBar() {
        let bar = makeController()
        clock.fire()
        clock.fire()
        XCTAssertEqual(bar.phase, .hidden)

        bar.pageDidScroll()
        XCTAssertEqual(bar.phase, .pill)
    }

    /// The rule Andy asked for in so many words: scrolling never expands.
    func testScrollingNeverExpandsTheBar() {
        let bar = makeController()
        clock.fire()
        XCTAssertEqual(bar.phase, .pill)
        for _ in 0..<5 {
            bar.pageDidScroll()
            XCTAssertEqual(bar.phase, .pill)
        }
    }

    /// Scrolling the page is not using the bar, so an expanded bar goes back
    /// to the pill rather than riding along.
    func testScrollingCollapsesAnExpandedBarToThePill() {
        let bar = makeController()
        XCTAssertEqual(bar.phase, .expanded)
        bar.pageDidScroll()
        XCTAssertEqual(bar.phase, .pill)
    }

    /// The pill stays for as long as the scrolling lasts — a long flick must
    /// not flicker it away mid-gesture.
    func testThePillStaysWhileScrollingAndTheTimerOnlyStartsWhenItStops() {
        let bar = makeController()
        bar.pageDidScroll()
        XCTAssertFalse(clock.hasPending, "the still-timer should not run during a scroll")

        bar.scrollDidEnd()
        XCTAssertTrue(clock.hasPending)
        clock.fire()
        XCTAssertEqual(bar.phase, .hidden)
    }

    // MARK: (c) tap → expanded

    func testTappingThePillExpandsTheBar() {
        let bar = makeController()
        clock.fire()
        XCTAssertEqual(bar.phase, .pill)

        bar.pillTapped()
        XCTAssertEqual(bar.phase, .expanded)
    }

    /// Expanded is not a terminal state: it falls back to the pill and then to
    /// nothing on the same timer.
    func testAnExpandedBarCollapsesToThePillAndThenHides() {
        let bar = makeController()
        clock.fire()
        bar.pillTapped()
        XCTAssertEqual(bar.phase, .expanded)

        clock.fire()
        XCTAssertEqual(bar.phase, .pill)
        clock.fire()
        XCTAssertEqual(bar.phase, .hidden)
    }

    func testUsingTheBarKeepsIt() {
        let bar = makeController()
        clock.fire()
        bar.pillTapped()
        for _ in 0..<4 {
            bar.barInteracted()
            XCTAssertEqual(bar.phase, .expanded)
        }
        clock.fire()
        XCTAssertEqual(bar.phase, .pill)
    }

    // MARK: The whole sequence, in order

    func testTheFullStateMachine() {
        let bar = makeController()

        // still → hidden
        clock.fire()
        clock.fire()
        XCTAssertEqual(bar.phase, .hidden)

        // scroll → pill
        bar.pageDidScroll()
        XCTAssertEqual(bar.phase, .pill)
        bar.scrollDidEnd()

        // tap → expanded
        bar.pillTapped()
        XCTAssertEqual(bar.phase, .expanded)

        // still → pill → hidden
        clock.fire()
        XCTAssertEqual(bar.phase, .pill)
        clock.fire()
        XCTAssertEqual(bar.phase, .hidden)
    }

    // MARK: (d) swipe up opens the sidebar

    /// The pill carries the bar's own gesture table, so up is the drawer from
    /// either state — and the existing right-swipe is untouched.
    func testSwipingUpFromTheBarOpensTheSidebar() {
        XCTAssertEqual(
            BarSwipeGesture.resolve(direction: .up, isSidebarOpen: false), .openSidebar)
        XCTAssertEqual(
            BarSwipeGesture.resolve(direction: .right, isSidebarOpen: false), .openSidebar)
    }

    /// Up means the drawer whichever edge it lives on — only right/left mirror.
    func testUpOpensTheSidebarOnEitherEdge() {
        for edge in SidebarEdge.allCases {
            XCTAssertEqual(
                BarSwipeGesture.action(direction: .up, isSidebarOpen: false, edge: edge),
                .openSidebar, "up should reach the drawer with the sidebar on \(edge)")
        }
    }

    // MARK: Page taps and the grabber

    func testTappingThePagePutsTheChromeAwayImmediately() {
        let bar = makeController()
        bar.pageTapped()
        XCTAssertEqual(bar.phase, .hidden)
        XCTAssertFalse(clock.hasPending)
    }

    func testTheGrabberRevealsTheWholeBar() {
        let bar = makeController()
        clock.fire()
        clock.fire()
        XCTAssertEqual(bar.phase, .hidden)

        bar.grabberRevealed()
        XCTAssertEqual(bar.phase, .expanded)
        // And it is not permanent — it falls on the same ladder.
        XCTAssertTrue(clock.hasPending)
    }

    // MARK: A covered page

    /// The overlay covers the bar, so a countdown that runs behind it can only
    /// do harm: it buzzes a hide haptic at someone typing a search.
    func testACoveredPagePausesTheStillTimer() {
        let bar = makeController()
        bar.coveredDidChange(true)
        XCTAssertEqual(bar.phase, .expanded)
        XCTAssertFalse(clock.hasPending, "the still-timer should not run behind the omnibox")

        haptics = []
        bar.coveredDidChange(false)
        XCTAssertEqual(haptics, [], "closing the omnibox should not buzz")
        XCTAssertTrue(clock.hasPending, "the timer should resume once the omnibox is gone")
    }

    /// You opened the omnibox from a pill; you should not be handed a pill
    /// back when you dismiss it.
    func testUncoveringHandsBackTheWholeBar() {
        let bar = makeController()
        clock.fire()
        clock.fire()
        XCTAssertEqual(bar.phase, .hidden)

        bar.coveredDidChange(true)
        XCTAssertEqual(bar.phase, .expanded)
        bar.coveredDidChange(false)
        XCTAssertEqual(bar.phase, .expanded)
        clock.fire()
        XCTAssertEqual(bar.phase, .pill)
    }

    // MARK: Compact mode off

    func testWithCompactModeOffTheBarIsSimplyAlwaysThere() {
        let bar = makeController(enabled: false)
        XCTAssertEqual(bar.phase, .expanded)
        XCTAssertFalse(clock.hasPending)

        bar.pageDidScroll()
        bar.scrollDidEnd()
        bar.pageTapped()
        XCTAssertEqual(bar.phase, .expanded)
    }

    func testLeavingCompactModeRestoresTheBar() {
        let bar = makeController()
        clock.fire()
        clock.fire()
        XCTAssertEqual(bar.phase, .hidden)

        bar.isEnabled = false
        XCTAssertEqual(bar.phase, .expanded)
    }

    // MARK: Haptics

    /// Show, expand and hide each get one — and nothing fires twice for one
    /// change, which is `Haptics`' own house rule.
    func testHapticsOnShowExpandAndHide() {
        let bar = makeController()
        clock.fire()
        clock.fire()
        XCTAssertEqual(bar.phase, .hidden)
        XCTAssertEqual(haptics, [.compactBarHide])

        haptics = []
        bar.pageDidScroll()
        XCTAssertEqual(haptics, [.compactBarShow])

        haptics = []
        bar.pillTapped()
        XCTAssertEqual(haptics, [.compactBarExpand])

        haptics = []
        bar.pageTapped()
        XCTAssertEqual(haptics, [.compactBarHide])
    }

    /// Collapsing from the full bar to the pill is not a disappearance, and
    /// buzzing for it would be noise on every idle page.
    func testCollapsingToThePillIsSilent() {
        let bar = makeController()
        haptics = []
        clock.fire()
        XCTAssertEqual(bar.phase, .pill)
        XCTAssertEqual(haptics, [])
    }

    func testAScrollThatChangesNothingIsSilent() {
        let bar = makeController()
        clock.fire()
        haptics = []
        bar.pageDidScroll()
        bar.pageDidScroll()
        XCTAssertEqual(haptics, [])
    }
}
