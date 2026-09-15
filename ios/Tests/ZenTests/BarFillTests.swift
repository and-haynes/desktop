//  BarFillTests.swift
//  The floating bar's backing is a persisted choice (#00891), and the default
//  matters: a fresh install must get Liquid Glass, and a session file written
//  before the setting existed must not throw (SessionStore reads a decode
//  failure as "no session" — i.e. every tab gone).

import XCTest

@testable import Zen

final class BarFillTests: XCTestCase {

    func testTheDefaultIsLiquidGlass() {
        XCTAssertEqual(ZenSettings().barFill, .liquidGlass)
    }

    func testEveryFillRoundTrips() throws {
        for fill in BarFill.allCases {
            var settings = ZenSettings()
            settings.barFill = fill
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(ZenSettings.self, from: data).barFill, fill)
        }
    }

    func testAnOlderSessionDecodesToTheDefault() throws {
        let json = Data(#"{"searchEngine":"bing","layout":"fullScreen"}"#.utf8)
        let settings = try JSONDecoder().decode(ZenSettings.self, from: json)
        XCTAssertEqual(settings.barFill, .liquidGlass)
        XCTAssertEqual(settings.layout, .fullScreen)
    }

    func testTheSettingSurvivesASnapshotRoundTrip() throws {
        var snapshot = SessionSnapshot()
        snapshot.settings.barFill = .matte
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(
            try JSONDecoder().decode(SessionSnapshot.self, from: data).settings.barFill, .matte)
    }

    /// Only Liquid Glass changes the bar's shape; the other two keep Zen's
    /// `--border-radius-medium` corners.
    func testOnlyGlassIsCapsuleShaped() {
        XCTAssertTrue(BarFill.liquidGlass.isCapsule)
        XCTAssertFalse(BarFill.matte.isCapsule)
        XCTAssertFalse(BarFill.transparent.isCapsule)
    }

    func testEveryFillIsNamedAndExplained() {
        for fill in BarFill.allCases {
            XCTAssertFalse(fill.displayName.isEmpty, "\(fill) has no name")
            XCTAssertFalse(fill.detail.isEmpty, "\(fill) has no explanation")
        }
    }
}
