//  ZenGradient.swift
//  Port of src/zen/spaces/ZenGradientGenerator.mjs.
//
//  Upstream a space's theme is up to three colour "dots" placed on a 380×380
//  HSL wheel, plus an opacity and a film-grain amount. The dots are rendered as
//  layered CSS gradients (never a mesh), and one dot — the primary — is fed
//  back through `getAccentColorForUI()` to become `--zen-primary-color`, from
//  which zen-theme.css derives the whole UI palette.
//
//  This file keeps the same data shape and the same maths so a space themed on
//  desktop and one themed here land in the same place.

import Foundation
import SwiftUI

/// One colour stop on the wheel.
struct ZenGradientDot: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var color: ZenColor
    var isPrimary: Bool = false
    /// Normalised position on the wheel (-1...1 on both axes, centre 0,0).
    /// Kept so a theme survives a round-trip through the editor.
    var position: CGPoint = .zero

    private enum CodingKeys: String, CodingKey {
        case id, color, isPrimary, positionX, positionY
    }

    init(color: ZenColor, isPrimary: Bool = false, position: CGPoint = .zero) {
        self.color = color
        self.isPrimary = isPrimary
        self.position = position
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        color = try c.decode(ZenColor.self, forKey: .color)
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        let x = try c.decodeIfPresent(Double.self, forKey: .positionX) ?? 0
        let y = try c.decodeIfPresent(Double.self, forKey: .positionY) ?? 0
        position = CGPoint(x: x, y: y)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(color, forKey: .color)
        try c.encode(isPrimary, forKey: .isPrimary)
        try c.encode(position.x, forKey: .positionX)
        try c.encode(position.y, forKey: .positionY)
    }
}

/// The colour-harmony presets from `nsZenThemePicker.colorHarmonies`. Adding a
/// dot snaps it to one of these hue offsets from the primary dot.
enum ZenColorHarmony: String, CaseIterable, Codable, Identifiable, Sendable {
    case floating
    case complementary
    case singleAnalogous
    case splitComplementary
    case analogous
    case triadic

    var id: String { rawValue }

    /// Hue offsets in degrees, exactly as upstream declares them.
    var angles: [Double] {
        switch self {
        case .floating: return []
        case .complementary: return [180]
        case .singleAnalogous: return [310]
        case .splitComplementary: return [150, 210]
        case .analogous: return [50, 310]
        case .triadic: return [120, 240]
        }
    }

    var displayName: String {
        switch self {
        case .floating: return "Free"
        case .complementary: return "Complementary"
        case .singleAnalogous: return "Analogous"
        case .splitComplementary: return "Split"
        case .analogous: return "Double"
        case .triadic: return "Triadic"
        }
    }
}

/// A space's theme: `{ type: "gradient", gradientColors, opacity, texture }`.
struct ZenTheme: Codable, Equatable, Sendable {
    /// `static MAX_DOTS = 3`
    static let maxDots = 3

    var dots: [ZenGradientDot] = []
    /// Default `opacity: 0.5` from `getTheme([])`.
    var opacity: Double = 0.5
    /// Film-grain amount, 0...1. Drives `--zen-grainy-background-opacity`.
    var texture: Double = 0
    var harmony: ZenColorHarmony = .floating

    static let `default` = ZenTheme()

    var isEmpty: Bool { dots.isEmpty }

    /// `getPrimaryColor()` — the dot flagged primary, else the middle dot.
    var primaryDotColor: ZenColor? {
        guard !dots.isEmpty else { return nil }
        if let p = dots.first(where: { $0.isPrimary }) { return p.color }
        return dots[dots.count / 2].color
    }

    /// The value zen-theme.css consumes as `--zen-primary-color`.
    func accentColor(isDark: Bool) -> ZenColor {
        guard let base = primaryDotColor else { return ZenTokens.defaultAccent }
        return ZenGradientGenerator.accentColorForUI(base, isDark: isDark)
    }

    /// `shouldBeDarkMode()` — a strongly-tinted space overrides the system
    /// scheme with whichever text colour actually contrasts against it.
    /// Returns nil for an unthemed space so the system setting wins.
    var forcedDarkMode: Bool? {
        guard let accent = primaryDotColor else { return nil }
        let lightText = ZenColor(r: 1, g: 1, b: 1, a: 0.9)
        let darkText = ZenColor(r: 0, g: 0, b: 0, a: 0.9)
        let overLight = lightText.mix(accent, weight: 0.9)
        let overDark = darkText.mix(accent, weight: 0.9)
        // Higher contrast against the accent wins; light text winning means the
        // surface is dark.
        return overLight.contrastRatio(against: accent)
            > overDark.contrastRatio(against: accent)
    }

    mutating func setPrimary(_ id: UUID) {
        for i in dots.indices { dots[i].isPrimary = (dots[i].id == id) }
    }

    /// `fixTheme()` — guarantee exactly one primary and no more than MAX_DOTS.
    mutating func normalise() {
        if dots.count > Self.maxDots { dots = Array(dots.prefix(Self.maxDots)) }
        guard !dots.isEmpty else { return }
        if !dots.contains(where: { $0.isPrimary }) { dots[0].isPrimary = true }
        var seenPrimary = false
        for i in dots.indices {
            if dots[i].isPrimary {
                if seenPrimary { dots[i].isPrimary = false } else { seenPrimary = true }
            }
        }
    }
}

enum ZenGradientGenerator {
    /// `getColorFromPosition()` — hue is the angle from the wheel centre;
    /// saturation is pinned to a narrow 90–100% band; lightness falls off with
    /// distance (drag outward → brighter).
    ///
    /// `position` is normalised to -1...1 on both axes.
    static func color(at position: CGPoint, grayscale: Bool = false) -> ZenColor {
        let distance = min(sqrt(position.x * position.x + position.y * position.y), 1)
        var angle = atan2(position.y, position.x) * 180 / .pi
        if angle < 0 { angle += 360 }
        let saturation = grayscale ? 0 : 90 + (1 - distance) * 10
        let lightness = (1 - distance) * 100
        return ZenColor(hueDegrees: angle, saturation: saturation, lightness: lightness.rounded())
    }

    /// Inverse, so an existing theme can be re-opened in the editor.
    static func position(of color: ZenColor) -> CGPoint {
        let (hue, _, lightness) = color.hsl
        let distance = 1 - (lightness / 100)
        let radians = hue * .pi / 180
        return CGPoint(x: cos(radians) * distance, y: sin(radians) * distance)
    }

    /// `getAccentColorForUI()` — nudge the raw wheel colour toward a lightness
    /// that reads well in the current scheme before it becomes
    /// `--zen-primary-color`. Greys pass through untouched.
    static func accentColorForUI(_ color: ZenColor, isDark: Bool) -> ZenColor {
        if color.r == color.g && color.g == color.b { return color }
        var (hue, saturation, lightness) = color.hsl
        saturation = min(100, saturation + 30)
        let target = isDark ? 62.0 : 42.0
        lightness = lightness * 0.4 + target * 0.6
        return ZenColor(hueDegrees: hue, saturation: saturation, lightness: lightness)
    }

    /// Suggest the colours for the remaining dots given a primary and a
    /// harmony, mirroring how the desktop picker snaps new dots into place.
    static func harmonised(primary: ZenColor, harmony: ZenColorHarmony) -> [ZenColor] {
        let (hue, saturation, lightness) = primary.hsl
        return harmony.angles.map {
            ZenColor(hueDegrees: hue + $0, saturation: saturation, lightness: lightness)
        }
    }

    /// Build a full theme from a single seed colour — what the accent picker
    /// hands us when the user taps a swatch rather than opening the wheel.
    static func theme(seed: ZenColor, harmony: ZenColorHarmony = .splitComplementary) -> ZenTheme {
        var theme = ZenTheme(harmony: harmony)
        var dots = [ZenGradientDot(color: seed, isPrimary: true, position: position(of: seed))]
        for c in harmonised(primary: seed, harmony: harmony) {
            guard dots.count < ZenTheme.maxDots else { break }
            dots.append(ZenGradientDot(color: c, position: position(of: c)))
        }
        theme.dots = dots
        theme.normalise()
        return theme
    }
}
