//  SepiaAppearanceTests.swift
//  Sepia is not a tint applied over the light palette — it is the same
//  `color-mix` chain run against a paper/ink pair instead of a grey one
//  (#00890). These pin that, because "it looks warm enough" is exactly the
//  standard that produces a scheme with one cold token in it.

import XCTest

@testable import Zen

final class SepiaAppearanceTests: XCTestCase {

    private let accent = ZenColor(hex: "#5B6EE1")!

    private var sepia: ZenPalette { ZenPalette(accent: accent, base: .sepia) }
    private var light: ZenPalette { ZenPalette(accent: accent, base: .light) }
    private var dark: ZenPalette { ZenPalette(accent: accent, base: .dark) }

    // MARK: Derivation

    func testSepiaDerivesFromPaperAndInk() {
        XCTAssertEqual(sepia.brandingBG, ZenTokens.sepiaPaper)
        XCTAssertEqual(sepia.brandingBGReverse, ZenTokens.sepiaInk)
        XCTAssertEqual(ZenTokens.sepiaPaper.hexString.uppercased(), "#F4ECD8")
        XCTAssertEqual(ZenTokens.sepiaInk.hexString.uppercased(), "#5B4636")
    }

    /// Sepia is a *light* scheme: every readability branch has to take the
    /// light answer or the text comes out white on paper.
    func testSepiaIsALightScheme() {
        XCTAssertFalse(sepia.isDark)
        XCTAssertTrue(sepia.isSepia)
        XCTAssertFalse(light.isSepia)
        XCTAssertFalse(dark.isSepia)
    }

    func testBodyTextIsInkNotBlack() {
        let text = sepia.text
        XCTAssertEqual(text.r, ZenTokens.sepiaInk.r, accuracy: 0.001)
        XCTAssertEqual(text.g, ZenTokens.sepiaInk.g, accuracy: 0.001)
        XCTAssertEqual(text.b, ZenTokens.sepiaInk.b, accuracy: 0.001)
        // Warm: more red than blue.
        XCTAssertGreaterThan(text.r, text.b)
    }

    /// The point of the whole exercise. Every chrome surface has to be warmer
    /// than its light-scheme counterpart, not just the sidebar.
    func testEveryChromeSurfaceIsWarmerThanTheLightScheme() {
        let pairs: [(String, ZenColor, ZenColor)] = [
            ("branding", sepia.brandingBG, light.brandingBG),
            ("dialog", sepia.dialogBackground, light.dialogBackground),
            ("urlbar", sepia.urlbarBackground, light.urlbarBackground),
            ("browser", sepia.mainBrowserBackground, light.mainBrowserBackground),
            ("toolbar", sepia.themedToolbarBG, light.themedToolbarBG),
            ("tertiary", sepia.tertiary, light.tertiary),
            ("inputBG", sepia.inputBG, light.inputBG),
        ]
        for (name, warm, cool) in pairs {
            XCTAssertGreaterThan(
                warm.r - warm.b, cool.r - cool.b,
                "\(name) is not warmer in sepia than in light")
        }
    }

    /// A "warm" surface that is also darker than the light one would just be
    /// a dim scheme. Paper has to stay paper.
    func testTheChromeStaysLight() {
        for surface in [
            sepia.brandingBG, sepia.dialogBackground, sepia.urlbarBackground,
            sepia.mainBrowserBackground, sepia.themedToolbarBG,
        ] {
            XCTAssertGreaterThan(
                surface.hsl.lightness, 80, "a paper surface should be near-white in lightness")
        }
    }

    /// The accent still drives the palette — sepia changes the base, not the
    /// derivation, so a different accent still moves every token.
    func testTheAccentStillDrivesTheDerivation() {
        let other = ZenPalette(accent: ZenColor(hex: "#2E8B57")!, base: .sepia)
        XCTAssertNotEqual(other.primary, sepia.primary)
        XCTAssertNotEqual(other.hoverBG, sepia.hoverBG)
        XCTAssertNotEqual(other.sidebarIconFill, sepia.sidebarIconFill)
        // …but the paper does not move.
        XCTAssertEqual(other.brandingBG, sepia.brandingBG)
    }

    func testTheBooleanInitStillMeansLightAndDark() {
        XCTAssertEqual(ZenPalette(accent: accent, isDark: false).base, .light)
        XCTAssertEqual(ZenPalette(accent: accent, isDark: true).base, .dark)
    }

    // MARK: The appearance mode

    func testSepiaResolvesToItsOwnBase() {
        XCTAssertEqual(
            AppearanceMode.sepia.surfaceBase(systemDark: true, spacePrefersDark: true), .sepia,
            "an explicit Sepia beats both the system and the space's heuristic")
        XCTAssertEqual(
            AppearanceMode.system.surfaceBase(systemDark: true, spacePrefersDark: nil), .dark)
        XCTAssertEqual(
            AppearanceMode.light.surfaceBase(systemDark: true, spacePrefersDark: true), .light)
    }

    func testSepiaForcesTheLightColorScheme() {
        XCTAssertEqual(AppearanceMode.sepia.preferredColorScheme, .light)
        XCTAssertFalse(AppearanceMode.sepia.isDark(systemDark: true, spacePrefersDark: true))
    }

    func testSepiaIsOfferedInTheSettingsList() {
        XCTAssertTrue(AppearanceMode.allCases.contains(.sepia))
        XCTAssertEqual(AppearanceMode.sepia.displayName, "Sepia")
        XCTAssertFalse(AppearanceMode.sepia.symbol.isEmpty)
    }

    // MARK: Persistence

    func testTheAppearanceChoicePersists() throws {
        var settings = ZenSettings()
        settings.appearance = .sepia
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ZenSettings.self, from: data).appearance, .sepia)
    }

    func testThePageTintIsOffByDefaultAndPersists() throws {
        XCTAssertFalse(ZenSettings().sepiaTintsPages)
        var settings = ZenSettings()
        settings.sepiaTintsPages = true
        let data = try JSONEncoder().encode(settings)
        XCTAssertTrue(try JSONDecoder().decode(ZenSettings.self, from: data).sepiaTintsPages)
    }

    func testAnOlderSessionDecodesToTheDefaults() throws {
        let json = Data(##"{"appearance":"sepia"}"##.utf8)
        let settings = try JSONDecoder().decode(ZenSettings.self, from: json)
        XCTAssertEqual(settings.appearance, .sepia)
        XCTAssertFalse(settings.sepiaTintsPages)
    }

    // MARK: The page tint script

    /// It runs on every navigation and on every settings change, so it has to
    /// be safe to run twice.
    func testTheTintScriptIsIdempotentAndReversible() {
        let on = SepiaPageTint.script(enabled: true)
        XCTAssertTrue(on.contains("zen-sepia-tint"))
        XCTAssertTrue(on.contains("if (existing) { return; }"), "must not add a second sheet")
        XCTAssertTrue(on.contains(SepiaPageTint.tintHex))

        let off = SepiaPageTint.script(enabled: false)
        XCTAssertTrue(off.contains("existing.remove()"))
    }

    /// An overlay, not `filter:` on the root — a root filter establishes a
    /// containing block and silently breaks `position: fixed` across the web.
    func testTheTintDoesNotFilterTheRootElement() {
        let script = SepiaPageTint.script(enabled: true)
        XCTAssertFalse(script.contains("filter:"))
        XCTAssertTrue(script.contains("mix-blend-mode:multiply"))
        XCTAssertTrue(script.contains("pointer-events:none"))
    }
}
