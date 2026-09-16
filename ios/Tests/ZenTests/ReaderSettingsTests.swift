//  ReaderSettingsTests.swift
//  The reader's settings value: clamping, decoding forwards-compatibly, the
//  colours each theme derives, and the CSS those produce (#008BC).
//
//  None of this needs a web view. The part that does — whether Readability
//  finds the article — is Mozilla's library's job and is not re-verified here;
//  what *is* ours is everything between a slider and a CSS custom property, and
//  that is all pure.

import XCTest

@testable import Zen

final class ReaderSettingsTests: XCTestCase {

    // MARK: Clamping

    func testClampingPullsEveryNumericSettingIntoRange() {
        var settings = ReaderSettings()
        settings.fontSize = 900
        settings.lineHeight = 0.1
        settings.letterSpacing = 5
        settings.contentWidth = 10_000
        settings.paragraphSpacing = -4
        settings.dim = 3
        settings.speechRate = 12

        let clamped = settings.clamped()
        XCTAssertEqual(clamped.fontSize, ReaderSettings.fontSizeRange.upperBound)
        XCTAssertEqual(clamped.lineHeight, ReaderSettings.lineHeightRange.lowerBound)
        XCTAssertEqual(clamped.letterSpacing, ReaderSettings.letterSpacingRange.upperBound)
        XCTAssertEqual(clamped.contentWidth, ReaderSettings.contentWidthRange.upperBound)
        XCTAssertEqual(clamped.paragraphSpacing, ReaderSettings.paragraphSpacingRange.lowerBound)
        XCTAssertEqual(clamped.dim, ReaderSettings.dimRange.upperBound)
        XCTAssertEqual(clamped.speechRate, ReaderSettings.speechRateRange.upperBound)
    }

    /// The dim is the one that matters most: a slider that can reach 1.0 puts
    /// an opaque black sheet over the reader, including over the control that
    /// would take it off again.
    func testTheDimCanNeverBlackTheScreenOut() {
        XCTAssertLessThan(ReaderSettings.dimRange.upperBound, 1.0)
        var settings = ReaderSettings()
        settings.dim = .infinity
        XCTAssertLessThan(settings.clamped().dim, 1.0)
    }

    /// NaN has no nearest bound, so clamping it has to mean "the default"
    /// rather than min or max — `min(max(nan, lo), hi)` is nan on both.
    func testNonFiniteValuesFallBackToTheDefaultNotToABound() {
        var settings = ReaderSettings()
        settings.fontSize = .nan
        settings.lineHeight = .infinity
        settings.contentWidth = -.infinity
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.fontSize, ReaderSettings().fontSize)
        XCTAssertEqual(clamped.lineHeight, ReaderSettings().lineHeight)
        XCTAssertEqual(clamped.contentWidth, ReaderSettings().contentWidth)
    }

    func testValuesInsideTheRangeAreLeftAlone() {
        var settings = ReaderSettings()
        settings.fontSize = 21
        settings.lineHeight = 1.75
        settings.contentWidth = ReaderSettings.narrowWidth
        XCTAssertEqual(settings.clamped(), settings)
    }

    // MARK: Decoding

    /// The same contract `ZenSettings` keeps: a file written before a setting
    /// existed must still decode, or shipping a new knob silently resets
    /// everyone's per-site choices.
    func testAFileMissingEveryNewKeyStillDecodes() throws {
        let json = Data(#"{"fontSize": 24}"#.utf8)
        let decoded = try JSONDecoder().decode(ReaderSettings.self, from: json)
        XCTAssertEqual(decoded.fontSize, 24)
        XCTAssertEqual(decoded.font, ReaderSettings().font)
        XCTAssertEqual(decoded.theme, ReaderSettings().theme)
        XCTAssertEqual(decoded.speechRate, ReaderSettings().speechRate)
    }

    func testSettingsRoundTripThroughJSON() throws {
        var settings = ReaderSettings()
        settings.font = .charter
        settings.theme = .custom
        settings.customBackground = ZenColor(hex: "#102030")!
        settings.customText = ZenColor(hex: "#E0E0E0")!
        settings.customLink = ZenColor(hex: "#44AAFF")!
        settings.alignment = .justified
        settings.hyphenation = false
        settings.dropCaps = true
        settings.showImages = false
        settings.dim = 0.4

        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ReaderSettings.self, from: data), settings)
    }

    // MARK: Themes

    func testEveryThemeIsADistinctBackgroundAndReadableAgainstItsText() {
        var backgrounds: Set<String> = []
        for theme in ReaderTheme.allCases where theme != .custom {
            var settings = ReaderSettings()
            settings.theme = theme
            let palette = settings.palette
            backgrounds.insert(palette.background.hexString)
            XCTAssertGreaterThan(
                palette.text.contrastRatio(against: palette.background), 4.5,
                "\(theme.displayName) text fails WCAG AA against its own background")
            XCTAssertGreaterThan(
                palette.link.contrastRatio(against: palette.background), 3.0,
                "\(theme.displayName) links are not distinguishable from the page")
        }
        XCTAssertEqual(
            backgrounds.count, ReaderTheme.allCases.count - 1,
            "two themes share a background colour, so one of them is decoration")
    }

    /// Black is *true* black, not "a darker dark" — that is the whole reason
    /// it exists alongside Dark on an OLED phone.
    func testBlackIsTrueBlackAndDarkIsNot() {
        var black = ReaderSettings()
        black.theme = .black
        XCTAssertEqual(black.palette.background.hexString, "#000000")

        var dark = ReaderSettings()
        dark.theme = .dark
        XCTAssertNotEqual(dark.palette.background.hexString, "#000000")
    }

    func testTheCustomThemeUsesTheColoursItWasGiven() {
        var settings = ReaderSettings()
        settings.theme = .custom
        settings.customBackground = ZenColor(hex: "#123456")!
        settings.customText = ZenColor(hex: "#FEDCBA")!
        settings.customLink = ZenColor(hex: "#00FF00")!
        let palette = settings.palette
        XCTAssertEqual(palette.background.hexString, "#123456")
        XCTAssertEqual(palette.text.hexString, "#FEDCBA")
        XCTAssertEqual(palette.link.hexString, "#00FF00")
    }

    /// Secondary text and rules are *mixed* rather than chosen, so a custom
    /// theme cannot produce a byline the same colour as its own page.
    func testDerivedColoursSitBetweenTheTwoChosenOnes() {
        var settings = ReaderSettings()
        settings.theme = .custom
        settings.customBackground = ZenColor.white
        settings.customText = ZenColor.black
        let palette = settings.palette
        XCTAssertGreaterThan(palette.secondary.luminance, palette.text.luminance)
        XCTAssertLessThan(palette.secondary.luminance, palette.background.luminance)
        XCTAssertGreaterThan(palette.border.luminance, palette.secondary.luminance)
    }

    /// The chrome over the page decides light or dark from the *background*,
    /// which is the surface it sits on.
    func testTheChromeFollowsTheBackgroundNotTheTheme() {
        var pale = ReaderSettings()
        pale.theme = .custom
        pale.customBackground = ZenColor(hex: "#FAFAF0")!
        pale.customText = ZenColor(hex: "#202020")!
        XCTAssertFalse(pale.palette.isDark)

        var deep = pale
        deep.customBackground = ZenColor(hex: "#101014")!
        deep.customText = ZenColor(hex: "#EEEEEE")!
        XCTAssertTrue(deep.palette.isDark)
    }

    // MARK: Faces

    func testEveryFaceEndsInAGenericFamily() {
        let generics = ["serif", "sans-serif", "monospace", "system-ui"]
        for font in ReaderFont.allCases {
            let last = font.cssStack.split(separator: ",").last.map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            XCTAssertNotNil(last)
            XCTAssertTrue(
                generics.contains(last ?? ""),
                "\(font.displayName) falls back to nothing in particular")
        }
    }

    /// Nothing is bundled, so nothing may name a file. A stack that referenced
    /// a web font would render as Times on every device.
    func testNoFaceNeedsAFontFile() {
        for font in ReaderFont.allCases {
            XCTAssertFalse(font.cssStack.contains(".woff"))
            XCTAssertFalse(font.cssStack.contains("url("))
        }
    }
}
