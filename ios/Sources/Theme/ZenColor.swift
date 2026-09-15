//  ZenColor.swift
//  A tiny sRGB colour value type with CSS `color-mix(in srgb, ...)` semantics.
//
//  Zen's entire palette is *derived*: zen-theme.css declares one input
//  (`--zen-primary-color`, the space's accent) and mixes it against the
//  branding base to produce every other token. To reproduce Zen's look on iOS
//  faithfully we have to reproduce that mixing, including the premultiplied
//  alpha rule CSS uses — otherwise mixes against `transparent` come out muddy
//  rather than simply translucent.

import Foundation
import SwiftUI

/// A colour in extended sRGB with straight (non-premultiplied) alpha,
/// components in 0...1.
struct ZenColor: Equatable, Hashable, Codable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// 8-bit convenience, matching how the CSS spells its constants.
    init(_ r8: Int, _ g8: Int, _ b8: Int, _ a: Double = 1) {
        self.init(r: Double(r8) / 255, g: Double(g8) / 255, b: Double(b8) / 255, a: a)
    }

    /// `#rgb`, `#rrggbb` or `#rrggbbaa`. Returns nil on anything else so callers
    /// can fall back rather than silently rendering black.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF))
        } else {
            self.init(
                Int((v >> 24) & 0xFF), Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF),
                Double(v & 0xFF) / 255)
        }
    }

    static let transparent = ZenColor(r: 0, g: 0, b: 0, a: 0)
    static let black = ZenColor(0, 0, 0)
    static let white = ZenColor(255, 255, 255)

    var hexString: String {
        let c = { (v: Double) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// CSS `color-mix(in srgb, self <weight>, other <1 - weight>)`.
    ///
    /// CSS mixes in *premultiplied* alpha, which is why
    /// `color-mix(in srgb, red 50%, transparent)` is translucent red rather
    /// than a half-black smear. We do the same.
    func mix(_ other: ZenColor, weight: Double) -> ZenColor {
        let w = min(max(weight, 0), 1)
        let ow = 1 - w
        let outA = a * w + other.a * ow
        guard outA > 0 else { return .transparent }
        let pr = (r * a * w + other.r * other.a * ow) / outA
        let pg = (g * a * w + other.g * other.a * ow) / outA
        let pb = (b * a * w + other.b * other.a * ow) / outA
        return ZenColor(r: pr, g: pg, b: pb, a: outA)
    }

    func withAlpha(_ newAlpha: Double) -> ZenColor {
        ZenColor(r: r, g: g, b: b, a: newAlpha)
    }

    /// Relative luminance (WCAG), used to pick legible foregrounds over an
    /// arbitrary user-chosen accent.
    var luminance: Double {
        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    var isLight: Bool { luminance > 0.45 }

    var color: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    var uiColor: UIColor {
        UIColor(red: r, green: g, blue: b, alpha: a)
    }
}

extension ZenColor {
    /// HSB round-trip, used by the gradient generator to spread a set of dots
    /// around a seed hue.
    init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        let s = min(max(saturation, 0), 1)
        let v = min(max(brightness, 0), 1)
        let i = Int(h * 6)
        let f = h * 6 - Double(i)
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch i % 6 {
        case 0: self.init(r: v, g: t, b: p, a: alpha)
        case 1: self.init(r: q, g: v, b: p, a: alpha)
        case 2: self.init(r: p, g: v, b: t, a: alpha)
        case 3: self.init(r: p, g: q, b: v, a: alpha)
        case 4: self.init(r: t, g: p, b: v, a: alpha)
        default: self.init(r: v, g: p, b: q, a: alpha)
        }
    }

    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        var h = 0.0
        if delta > 0 {
            if maxV == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                h = (b - r) / delta + 2
            } else {
                h = (r - g) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxV == 0 ? 0 : delta / maxV, maxV)
    }
}

extension ZenColor {
    /// HSL, which is what Zen's colour wheel actually works in
    /// (`ZenGradientGenerator.getColorFromPosition` → standard HSL→RGB).
    /// `hue` in degrees 0..<360, `saturation`/`lightness` in 0...100.
    init(hueDegrees: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
        let h = (hueDegrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 360
        let s = min(max(saturation, 0), 100) / 100
        let l = min(max(lightness, 0), 100) / 100

        if s == 0 {
            self.init(r: l, g: l, b: l, a: alpha)
            return
        }
        func hueToRGB(_ p: Double, _ q: Double, _ tIn: Double) -> Double {
            var t = tIn
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        self.init(
            r: hueToRGB(p, q, h + 1.0 / 3),
            g: hueToRGB(p, q, h),
            b: hueToRGB(p, q, h - 1.0 / 3),
            a: alpha)
    }

    /// Inverse of the above. Hue in degrees, saturation/lightness in 0...100.
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let l = (maxV + minV) / 2
        let delta = maxV - minV
        guard delta > 0 else { return (0, 0, l * 100) }
        let s = delta / (1 - abs(2 * l - 1))
        var h: Double
        if maxV == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxV == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, min(s, 1) * 100, l * 100)
    }

    /// WCAG contrast ratio against another colour, both assumed opaque.
    func contrastRatio(against other: ZenColor) -> Double {
        let l1 = luminance
        let l2 = other.luminance
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
