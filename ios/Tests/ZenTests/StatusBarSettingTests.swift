//  StatusBarSettingTests.swift
//  The status bar is hidden by default, and that default has to survive both a
//  fresh install and a session file written before the setting existed.

import XCTest

@testable import Zen

final class StatusBarSettingTests: XCTestCase {

    func testTheStatusBarIsHiddenByDefault() {
        XCTAssertFalse(ZenSettings().showStatusBar)
    }

    func testTheChoicePersists() throws {
        var settings = ZenSettings()
        settings.showStatusBar = true
        let data = try JSONEncoder().encode(settings)
        XCTAssertTrue(try JSONDecoder().decode(ZenSettings.self, from: data).showStatusBar)
    }

    /// A session written before the setting existed must decode rather than
    /// throw — SessionStore reads a decode failure as "no session", so a
    /// missing key would cost someone all their tabs.
    func testAnOlderSessionDecodesToTheDefault() throws {
        let json = Data(#"{"searchEngine":"duckduckgo","sidebarPinnedOnPad":false}"#.utf8)
        let settings = try JSONDecoder().decode(ZenSettings.self, from: json)
        XCTAssertFalse(settings.showStatusBar)
        XCTAssertFalse(settings.sidebarPinnedOnPad)
    }

    /// The whole snapshot round-trips, which is what actually runs at launch.
    func testTheSettingSurvivesASnapshotRoundTrip() throws {
        var settings = ZenSettings()
        settings.showStatusBar = true
        var snapshot = SessionSnapshot()
        snapshot.settings = settings
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertTrue(restored.settings.showStatusBar)
    }
}
