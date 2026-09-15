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

    // MARK: Mapping through the layout (#00896)

    func testTheDefaultLayoutReachesTheTabsWithAnUpwardSwipe() {
        let layout = BarPreset.zen.layout
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: CGSize(width: 0, height: -60), velocity: slow, layout: layout),
            .sidebar)
    }

    func testHorizontalSwipesChangeTabsByDefault() {
        let layout = BarPreset.zen.layout
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: CGSize(width: -60, height: 0), velocity: slow, layout: layout),
            .nextTab)
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: CGSize(width: 60, height: 0), velocity: slow, layout: layout),
            .previousTab)
    }

    func testATapProducesNoAction() {
        XCTAssertNil(
            BarSwipeGesture.action(
                translation: .zero, velocity: .zero, layout: BarPreset.zen.layout))
    }

    /// The whole reason the mapping is a table: the customiser reassigns a
    /// direction without touching the gesture recogniser.
    func testTheMappingCanBeReassigned() {
        var layout = BarPreset.zen.layout
        layout.setGesture(.reloadStop, for: .swipeUp)
        XCTAssertEqual(
            BarSwipeGesture.action(
                translation: CGSize(width: 0, height: -60), velocity: slow, layout: layout),
            .reloadStop)
    }

    /// An explicit "nothing" is off, and must not fall back to a default.
    func testAGestureSetToNothingDoesNothing() {
        var layout = BarPreset.zen.layout
        layout.setGesture(.none, for: .swipeDown)
        XCTAssertNil(
            BarSwipeGesture.action(
                translation: CGSize(width: 0, height: 60), velocity: slow, layout: layout))
    }

    func testAnUnmappedDirectionDoesNothing() {
        var layout = BarPreset.zen.layout
        layout.gestures.removeValue(forKey: .swipeLeft)
        XCTAssertNil(
            BarSwipeGesture.action(
                translation: CGSize(width: -60, height: 0), velocity: slow, layout: layout))
    }

    func testEveryDirectionIsMappedByDefault() {
        let layout = BarPreset.zen.layout
        for direction in BarSwipeDirection.allCases {
            guard let gesture = BarGesture(direction: direction) else {
                return XCTFail("\(direction) has no gesture")
            }
            XCTAssertNotNil(layout.gestures[gesture], "\(direction) has no default action")
        }
    }
}
