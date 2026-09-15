//  AppearanceModeTests.swift
//  Follow system / Light / Dark (#00890).

import XCTest
import SwiftUI

@testable import Zen

final class AppearanceModeTests: XCTestCase {

    func testDefaultIsFollowSystem() {
        XCTAssertEqual(ZenSettings().appearance, .system)
    }

    func testExplicitModesForceTheirScheme() {
        XCTAssertEqual(AppearanceMode.light.preferredColorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.preferredColorScheme, .dark)
        XCTAssertNil(AppearanceMode.system.preferredColorScheme)
    }

    /// An explicit choice beats the space's own contrast heuristic — upstream
    /// only consults `shouldBeDarkMode()` when the scheme is "default".
    func testExplicitModesOverrideTheSpaceHeuristic() {
        XCTAssertFalse(AppearanceMode.light.isDark(systemDark: true, spacePrefersDark: true))
        XCTAssertTrue(AppearanceMode.dark.isDark(systemDark: false, spacePrefersDark: false))
    }

    func testFollowSystemPrefersTheSpaceThenTheSystem() {
        XCTAssertTrue(AppearanceMode.system.isDark(systemDark: false, spacePrefersDark: true))
        XCTAssertFalse(AppearanceMode.system.isDark(systemDark: true, spacePrefersDark: false))
        XCTAssertTrue(AppearanceMode.system.isDark(systemDark: true, spacePrefersDark: nil))
        XCTAssertFalse(AppearanceMode.system.isDark(systemDark: false, spacePrefersDark: nil))
    }

    /// Each mode must produce a genuinely different token set, or the control
    /// does nothing visible.
    func testEachModeDerivesADistinctPalette() {
        let accent = ZenColor(hex: "#5B6EE1")!
        let light = ZenPalette(accent: accent, isDark: false)
        let dark = ZenPalette(accent: accent, isDark: true)
        XCTAssertNotEqual(light.primary, dark.primary)
        XCTAssertNotEqual(light.brandingBG, dark.brandingBG)
        XCTAssertEqual(light.brandingBG, ZenTokens.brandingPaper)
        XCTAssertEqual(dark.brandingBG, ZenTokens.brandingDark)
    }

    func testEveryModeRoundTripsThroughJSON() throws {
        for mode in AppearanceMode.allCases {
            var settings = ZenSettings()
            settings.appearance = mode
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(
                try JSONDecoder().decode(ZenSettings.self, from: data).appearance, mode)
        }
    }

    /// A settings file written before the appearance control existed must
    /// still decode — otherwise shipping it wipes everyone's tabs.
    func testSettingsWrittenBeforeAppearanceStillDecode() throws {
        let legacy = """
            { "searchEngine": "google", "compactModeEnabled": true }
            """
        let decoded = try JSONDecoder().decode(ZenSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.appearance, .system)
        XCTAssertEqual(decoded.searchEngine, .google)
        XCTAssertTrue(decoded.compactModeEnabled)
    }
}
