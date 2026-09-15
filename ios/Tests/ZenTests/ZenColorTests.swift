//  ZenColorTests.swift
//  The palette is derived, not hand-picked, so the derivation is the thing
//  worth testing: if `color-mix` drifts, every surface in the app drifts with it.

import XCTest

@testable import Zen

final class ZenColorTests: XCTestCase {

    private func assertClose(
        _ a: ZenColor, _ b: ZenColor, accuracy: Double = 0.004,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.r, b.r, accuracy: accuracy, "red", file: file, line: line)
        XCTAssertEqual(a.g, b.g, accuracy: accuracy, "green", file: file, line: line)
        XCTAssertEqual(a.b, b.b, accuracy: accuracy, "blue", file: file, line: line)
        XCTAssertEqual(a.a, b.a, accuracy: accuracy, "alpha", file: file, line: line)
    }

    // MARK: Hex parsing

    func testHexParsing() {
        assertClose(ZenColor(hex: "#101010")!, ZenColor(16, 16, 16))
        assertClose(ZenColor(hex: "e2e2e2")!, ZenColor(226, 226, 226))
        // Shorthand expands each digit.
        assertClose(ZenColor(hex: "#fff")!, .white)
        // With alpha.
        assertClose(ZenColor(hex: "#00000080")!, ZenColor(r: 0, g: 0, b: 0, a: 128.0 / 255))
        XCTAssertNil(ZenColor(hex: "#gg0000"))
        XCTAssertNil(ZenColor(hex: "#12345"))
    }

    func testHexRoundTrip() {
        XCTAssertEqual(ZenColor(hex: "#5B6EE1")!.hexString, "#5B6EE1")
    }

    // MARK: color-mix semantics

    func testMixIsLinearInSRGB() {
        // color-mix(in srgb, white 50%, black 50%) == rgb(127.5, …)
        assertClose(ZenColor.white.mix(.black, weight: 0.5), ZenColor(r: 0.5, g: 0.5, b: 0.5))
    }

    func testMixWeightsAreHonoured() {
        // color-mix(in srgb, white 20%, black 80%)
        assertClose(ZenColor.white.mix(.black, weight: 0.2), ZenColor(r: 0.2, g: 0.2, b: 0.2))
    }

    /// The premultiplied-alpha rule. `color-mix(in srgb, red 50%, transparent)`
    /// is translucent *red*, not a half-black smear — get this wrong and every
    /// border in the app turns muddy.
    func testMixWithTransparentPreservesHue() {
        let red = ZenColor(255, 0, 0)
        let mixed = red.mix(.transparent, weight: 0.5)
        assertClose(mixed, ZenColor(r: 1, g: 0, b: 0, a: 0.5))
    }

    func testMixOfTwoFullyTransparentColoursIsTransparent() {
        let mixed = ZenColor.transparent.mix(.transparent, weight: 0.5)
        XCTAssertEqual(mixed.a, 0)
    }

    func testMixWeightIsClamped() {
        assertClose(ZenColor.white.mix(.black, weight: 2.0), .white)
        assertClose(ZenColor.white.mix(.black, weight: -1.0), .black)
    }

    // MARK: zen-theme.css derivation

    /// `--zen-colors-primary` dark: color-mix(in srgb, accent 20%, branding-bg 80%)
    func testPrimaryDerivationDark() {
        let accent = ZenColor(hex: "#5B6EE1")!
        let palette = ZenPalette(accent: accent, isDark: true)
        assertClose(palette.primary, accent.mix(ZenTokens.brandingDark, weight: 0.20))
    }

    /// `--zen-colors-primary` light: color-mix(in srgb, accent 50%, black 50%)
    func testPrimaryDerivationLight() {
        let accent = ZenColor(hex: "#5B6EE1")!
        let palette = ZenPalette(accent: accent, isDark: false)
        assertClose(palette.primary, accent.mix(.black, weight: 0.50))
    }

    /// `--zen-colors-secondary` light is built from *primary*, not the accent.
    func testSecondaryLightIsBuiltFromPrimary() {
        let accent = ZenColor(hex: "#5B6EE1")!
        let palette = ZenPalette(accent: accent, isDark: false)
        assertClose(palette.secondary, palette.primary.mix(.white, weight: 0.20))
    }

    /// `--zen-colors-border` light: color-mix(secondary 50%, transparent) — so
    /// it must come out as the secondary colour at half alpha.
    func testLightBorderIsHalfAlphaSecondary() {
        let palette = ZenPalette(accent: ZenColor(hex: "#5B6EE1")!, isDark: false)
        XCTAssertEqual(palette.border.a, 0.5, accuracy: 0.001)
        assertClose(palette.border.withAlpha(1), palette.secondary.withAlpha(1))
    }

    /// `--zen-colors-primary-foreground` light is the reversed branding colour.
    func testPrimaryForegroundLightIsBrandingReverse() {
        let palette = ZenPalette(accent: ZenColor(hex: "#5B6EE1")!, isDark: false)
        assertClose(palette.primaryForeground, ZenTokens.brandingDark)
    }

    func testBrandingBaseFollowsScheme() {
        XCTAssertEqual(ZenPalette(accent: .white, isDark: true).brandingBG, ZenTokens.brandingDark)
        XCTAssertEqual(ZenPalette(accent: .white, isDark: false).brandingBG, ZenTokens.brandingPaper)
    }

    /// The whole point of the derivation: one input drives everything.
    func testDifferentAccentsProduceDifferentPalettes() {
        let a = ZenPalette(accent: ZenColor(hex: "#5B6EE1")!, isDark: true)
        let b = ZenPalette(accent: ZenColor(hex: "#E15B6E")!, isDark: true)
        XCTAssertNotEqual(a.primary, b.primary)
        XCTAssertNotEqual(a.secondary, b.secondary)
        XCTAssertNotEqual(a.urlbarBackground, b.urlbarBackground)
    }

    // MARK: HSL

    func testHSLRoundTrip() {
        for hue in stride(from: 0.0, to: 360.0, by: 37.0) {
            let color = ZenColor(hueDegrees: hue, saturation: 90, lightness: 55)
            let (h, s, l) = color.hsl
            XCTAssertEqual(h, hue, accuracy: 0.5)
            XCTAssertEqual(s, 90, accuracy: 0.5)
            XCTAssertEqual(l, 55, accuracy: 0.5)
        }
    }

    func testZeroSaturationIsGrey() {
        let grey = ZenColor(hueDegrees: 210, saturation: 0, lightness: 50)
        XCTAssertEqual(grey.r, grey.g, accuracy: 0.001)
        XCTAssertEqual(grey.g, grey.b, accuracy: 0.001)
    }

    // MARK: getAccentColorForUI

    /// Greys pass through untouched — upstream short-circuits when r == g == b.
    func testAccentForUILeavesGreyAlone() {
        let grey = ZenColor(r: 0.4, g: 0.4, b: 0.4)
        assertClose(ZenGradientGenerator.accentColorForUI(grey, isDark: true), grey)
    }

    /// `lightness = l * 0.4 + target * 0.6`, target 62 dark / 42 light, and
    /// `saturation = min(100, s + 30)`.
    func testAccentForUIRetargetsLightness() {
        let seed = ZenColor(hueDegrees: 265, saturation: 60, lightness: 20)
        let dark = ZenGradientGenerator.accentColorForUI(seed, isDark: true)
        XCTAssertEqual(dark.hsl.lightness, 20 * 0.4 + 62 * 0.6, accuracy: 0.6)
        XCTAssertEqual(dark.hsl.saturation, 90, accuracy: 0.6)
        XCTAssertEqual(dark.hsl.hue, 265, accuracy: 0.6)

        let light = ZenGradientGenerator.accentColorForUI(seed, isDark: false)
        XCTAssertEqual(light.hsl.lightness, 20 * 0.4 + 42 * 0.6, accuracy: 0.6)
        // Dark mode aims lighter than light mode, by design.
        XCTAssertGreaterThan(dark.hsl.lightness, light.hsl.lightness)
    }

    func testAccentForUISaturationIsClamped() {
        let seed = ZenColor(hueDegrees: 100, saturation: 95, lightness: 50)
        let out = ZenGradientGenerator.accentColorForUI(seed, isDark: true)
        XCTAssertLessThanOrEqual(out.hsl.saturation, 100.001)
    }

    // MARK: Wheel

    /// `getColorFromPosition`: lightness falls off with distance from centre,
    /// saturation stays in the 90–100 band.
    func testWheelPositionMapping() {
        let centre = ZenGradientGenerator.color(at: .zero)
        XCTAssertEqual(centre.hsl.lightness, 100, accuracy: 1)

        let edge = ZenGradientGenerator.color(at: CGPoint(x: 1, y: 0))
        XCTAssertEqual(edge.hsl.lightness, 0, accuracy: 1)

        let mid = ZenGradientGenerator.color(at: CGPoint(x: 0.5, y: 0))
        XCTAssertGreaterThanOrEqual(mid.hsl.saturation, 89.9)
        XCTAssertLessThanOrEqual(mid.hsl.saturation, 100.1)
    }

    func testWheelGrayscaleForcesZeroSaturation() {
        let grey = ZenGradientGenerator.color(at: CGPoint(x: 0.5, y: 0.5), grayscale: true)
        XCTAssertEqual(grey.hsl.saturation, 0, accuracy: 0.001)
    }
}
