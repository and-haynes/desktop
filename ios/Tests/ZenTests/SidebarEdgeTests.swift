//  SidebarEdgeTests.swift
//  Sidebar position (#008A8): a pure (edge, gesture direction) -> action
//  mapping, the settings default/persistence/optional decoding, and the
//  layout helpers RootView uses to decide which side the sidebar occupies.

import XCTest

@testable import Zen

final class SidebarEdgeGestureTests: XCTestCase {

    // MARK: The pure (edge, direction) -> action mapping

    func testLeadingEdgeOpensOnRightOrUp() {
        XCTAssertEqual(
            BarSwipeGesture.action(direction: .right, isSidebarOpen: false, edge: .leading),
            .openSidebar)
        XCTAssertEqual(
            BarSwipeGesture.action(direction: .up, isSidebarOpen: false, edge: .leading),
            .openSidebar)
    }

    func testLeadingEdgeClosesOnLeftOrDown() {
        XCTAssertEqual(
            BarSwipeGesture.action(direction: .left, isSidebarOpen: true, edge: .leading),
            .closeSidebar)
        XCTAssertEqual(
            BarSwipeGesture.action(direction: .down, isSidebarOpen: true, edge: .leading),
            .closeSidebar)
    }

    /// The whole point: on the right edge the horizontal pair mirrors — left
    /// opens, right closes — while up/down (unrelated to which side the
    /// drawer is on) stay exactly as they were.
    func testTrailingEdgeMirrorsOnlyTheHorizontalPair() {
        XCTAssertEqual(
            BarSwipeGesture.action(direction: .left, isSidebarOpen: false, edge: .trailing),
            .openSidebar)
        XCTAssertEqual(
            BarSwipeGesture.action(direction: .right, isSidebarOpen: true, edge: .trailing),
            .closeSidebar)
        XCTAssertEqual(
            BarSwipeGesture.action(direction: .up, isSidebarOpen: false, edge: .trailing),
            .openSidebar)
        XCTAssertEqual(
            BarSwipeGesture.action(direction: .down, isSidebarOpen: true, edge: .trailing),
            .closeSidebar)
    }

    /// A direction that would already be true is not an action, on either
    /// edge — the haptic-for-nothing guard the un-edged version already has.
    func testAnAlreadyTrueActionStaysNoneOnBothEdges() {
        XCTAssertEqual(
            BarSwipeGesture.action(direction: .right, isSidebarOpen: true, edge: .leading), .none)
        XCTAssertEqual(
            BarSwipeGesture.action(direction: .left, isSidebarOpen: true, edge: .trailing), .none)
    }

    /// The edge-aware entry point must agree with feeding the same mapping
    /// through the general-purpose one directly.
    func testEdgeActionAgreesWithMappingLookup() {
        for direction in BarSwipeDirection.allCases {
            for isOpen in [true, false] {
                for edge in SidebarEdge.allCases {
                    XCTAssertEqual(
                        BarSwipeGesture.action(direction: direction, isSidebarOpen: isOpen, edge: edge),
                        BarSwipeGesture.resolve(
                            direction: direction, isSidebarOpen: isOpen, mapping: edge.swipeMapping))
                }
            }
        }
    }
}

// MARK: - Layout helpers

final class SidebarEdgeLayoutTests: XCTestCase {

    func testLeadingEdgeOccupiesTheLeadingAlignmentAndTransitionEdge() {
        XCTAssertEqual(SidebarEdge.leading.alignment, .leading)
        XCTAssertEqual(SidebarEdge.leading.swiftUIEdge, .leading)
    }

    func testTrailingEdgeOccupiesTheTrailingAlignmentAndTransitionEdge() {
        XCTAssertEqual(SidebarEdge.trailing.alignment, .trailing)
        XCTAssertEqual(SidebarEdge.trailing.swiftUIEdge, .trailing)
    }

    func testToggleSymbolPointsAtTheEdgeItOpens() {
        XCTAssertEqual(SidebarEdge.leading.toggleSymbolName, "sidebar.leading")
        XCTAssertEqual(SidebarEdge.trailing.toggleSymbolName, "sidebar.trailing")
    }
}

// MARK: - Settings default, persistence, and optional decoding

final class SidebarEdgeSettingsTests: XCTestCase {

    func testDefaultIsLeading() {
        XCTAssertEqual(ZenSettings().sidebarEdge, .leading)
    }

    func testEdgeRoundTripsThroughJSON() throws {
        var settings = ZenSettings()
        settings.sidebarEdge = .trailing
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ZenSettings.self, from: data)
        XCTAssertEqual(decoded.sidebarEdge, .trailing)
    }

    /// Settings written before this key existed must still decode, picking up
    /// the leading default — the same rule every new `ZenSettings` field
    /// follows, so an older session file never becomes undecodable.
    func testSettingsWrittenBeforeTheEdgeExistedStillDecode() throws {
        let legacy = """
            { "searchEngine": "duckduckgo", "compactModeEnabled": true }
            """
        let decoded = try JSONDecoder().decode(ZenSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.sidebarEdge, .leading)
        XCTAssertTrue(decoded.compactModeEnabled)
    }

    /// A snapshot with every other key present but this one missing is the
    /// exact shape an install upgrading into this feature has on disk.
    func testAnOtherwiseCompleteSnapshotMissingOnlyTheEdgeStillDecodes() throws {
        var settings = ZenSettings()
        settings.compactHideDelay = 2.5
        var dict = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
                as? [String: Any])
        dict.removeValue(forKey: "sidebarEdge")
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ZenSettings.self, from: data)
        XCTAssertEqual(decoded.sidebarEdge, .leading)
        XCTAssertEqual(decoded.compactHideDelay, 2.5, accuracy: 0.0001)
    }
}
