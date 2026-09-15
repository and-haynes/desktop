//  BarSwipeGestureTests.swift
//  The bar swipe is a pure decision over a drag, which is the whole reason it
//  is a free function: thresholds and direction mapping are exactly the sort of
//  thing that is miserable to verify by hand in a simulator.

import XCTest

@testable import Zen

final class BarSwipeGestureTests: XCTestCase {

    private let slow = CGSize(width: 0, height: 0)

    // MARK: Direction

    func testASlowShortDragMeansNothing() {
        XCTAssertNil(
            BarSwipeGesture.direction(translation: CGSize(width: 20, height: 0), velocity: slow))
    }

    func testADeliberateDragPastTheThresholdResolves() {
        XCTAssertEqual(
            BarSwipeGesture.direction(translation: CGSize(width: 44, height: 0), velocity: slow),
            .right)
        XCTAssertEqual(
            BarSwipeGesture.direction(translation: CGSize(width: -44, height: 0), velocity: slow),
            .left)
        XCTAssertEqual(
            BarSwipeGesture.direction(translation: CGSize(width: 0, height: -44), velocity: slow),
            .up)
        XCTAssertEqual(
            BarSwipeGesture.direction(translation: CGSize(width: 0, height: 44), velocity: slow),
            .down)
    }

    /// A flick is short but fast; it should not need the full 40pt.
    func testAFlickResolvesBeforeTheDistanceThreshold() {
        XCTAssertEqual(
            BarSwipeGesture.direction(
                translation: CGSize(width: 18, height: 0),
                velocity: CGSize(width: 900, height: 0)),
            .right)
    }

    /// …but a twitch is not a flick, however fast the sampled velocity is.
    func testAFastTwitchThatWentNowhereIsIgnored() {
        XCTAssertNil(
            BarSwipeGesture.direction(
                translation: CGSize(width: 4, height: 0),
                velocity: CGSize(width: 1200, height: 0)))
    }

    /// A diagonal must pick one axis, never fire two actions.
    func testTheDominantAxisWins() {
        XCTAssertEqual(
            BarSwipeGesture.direction(
                translation: CGSize(width: 60, height: -50), velocity: slow),
            .right)
        XCTAssertEqual(
            BarSwipeGesture.direction(
                translation: CGSize(width: 40, height: -70), velocity: slow),
            .up)
    }

    // MARK: Mapping

    func testRightAndUpOpenTheSidebar() {
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: CGSize(width: 60, height: 0), velocity: slow, isSidebarOpen: false),
            .openSidebar)
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: CGSize(width: 0, height: -60), velocity: slow, isSidebarOpen: false),
            .openSidebar)
    }

    func testLeftAndDownCloseTheSidebar() {
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: CGSize(width: -60, height: 0), velocity: slow, isSidebarOpen: true),
            .closeSidebar)
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: CGSize(width: 0, height: 60), velocity: slow, isSidebarOpen: true),
            .closeSidebar)
    }

    /// Opening an open sidebar is not an action; it must not reach the haptic.
    func testAnActionThatIsAlreadyTrueIsNotAnAction() {
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: CGSize(width: 60, height: 0), velocity: slow, isSidebarOpen: true),
            .none)
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: CGSize(width: -60, height: 0), velocity: slow, isSidebarOpen: false),
            .none)
    }

    func testATapProducesNoAction() {
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: .zero, velocity: .zero, isSidebarOpen: false),
            .none)
    }

    /// The mapping is a table precisely so the coming URL-bar customisation can
    /// reassign a direction. Proving it is injectable is proving that seam.
    func testTheMappingCanBeReassigned() {
        let swapped: [BarSwipeDirection: BarGestureAction] = [
            .right: .closeSidebar, .left: .openSidebar,
        ]
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: CGSize(width: 60, height: 0), velocity: slow, isSidebarOpen: true,
                mapping: swapped),
            .closeSidebar)
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: CGSize(width: 0, height: -60), velocity: slow, isSidebarOpen: false,
                mapping: swapped),
            .none, "an unmapped direction does nothing")
    }

    func testEveryDirectionIsMappedByDefault() {
        for direction in BarSwipeDirection.allCases {
            XCTAssertNotNil(
                BarSwipeGesture.defaultMapping[direction], "\(direction) has no default action")
        }
    }
}
