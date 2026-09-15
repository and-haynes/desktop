//  ZenGradientView.swift
//  Renders a ZenTheme with the same layer recipe `getGradient()` emits.
//
//  Upstream composites CSS background layers; SwiftUI has no `background-image`
//  list, so each CSS layer becomes a ZStack child — CSS paints the *first*
//  listed layer on top, so the ZStack order is reversed.

import SwiftUI

/// CSS-angle helpers. CSS measures a linear-gradient angle clockwise from
/// "to top"; SwiftUI wants two unit points.
private func cssLinearPoints(degrees: Double) -> (start: UnitPoint, end: UnitPoint) {
    let radians = degrees * .pi / 180
    let dx = sin(radians)
    let dy = -cos(radians)  // screen y grows downward
    return (
        UnitPoint(x: 0.5 - dx / 2, y: 0.5 - dy / 2),
        UnitPoint(x: 0.5 + dx / 2, y: 0.5 + dy / 2)
    )
}

/// `transparent` inside a CSS gradient interpolates in premultiplied alpha, so
/// it fades to nothing rather than to black. `Color.clear` would darken.
private func fadeOut(_ c: ZenColor) -> Color { c.withAlpha(0).color }

struct ZenGradientView: View {
    let theme: ZenTheme
    let isDark: Bool
    /// Space switching cross-fades the background; the swipe drives this.
    var opacityOverride: Double? = nil

    private var colors: [ZenColor] { theme.dots.map(\.color) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                base
                layers(size: geo.size)
                    .opacity(opacityOverride ?? theme.opacity)
                grain
            }
        }
        .ignoresSafeArea()
    }

    /// `getGradient()` with zero colours: the flat no-theme fallback.
    private var base: some View {
        (isDark ? ZenColor(hex: "#131313")! : ZenColor(hex: "#e9e9e9")!).color
    }

    @ViewBuilder
    private func layers(size: CGSize) -> some View {
        switch colors.count {
        case 0:
            EmptyView()

        case 1:
            colors[0].color

        case 2:
            // linear-gradient(-45deg, c1 0%, transparent 100%),
            // linear-gradient(135deg, c0 0%, transparent 100%)
            ZStack {
                linear(colors[0], degrees: 135)  // bottom layer
                linear(colors[1], degrees: -45)  // painted over it
            }

        default:
            // linear-gradient(-5deg, c[2] 10%, transparent 80%),
            // radial-gradient(circle at 95% 0%, c[1] 0%, transparent 75%),
            // radial-gradient(circle at 0% 0%, c[0] 10%, transparent 70%)
            ZStack {
                radial(colors[0], at: UnitPoint(x: 0, y: 0), start: 0.10, end: 0.70, size: size)
                radial(colors[1], at: UnitPoint(x: 0.95, y: 0), start: 0, end: 0.75, size: size)
                linear(colors[2], degrees: -5, start: 0.10, end: 0.80)
            }
        }
    }

    private func linear(
        _ c: ZenColor, degrees: Double, start: Double = 0, end: Double = 1
    ) -> some View {
        let points = cssLinearPoints(degrees: degrees)
        return LinearGradient(
            stops: [
                .init(color: c.color, location: start),
                .init(color: fadeOut(c), location: end),
            ],
            startPoint: points.start,
            endPoint: points.end)
    }

    /// CSS `circle at x y` defaults to farthest-corner sizing.
    private func radial(
        _ c: ZenColor, at centre: UnitPoint, start: Double, end: Double, size: CGSize
    ) -> some View {
        let cx = centre.x * size.width
        let cy = centre.y * size.height
        let farthest = max(
            hypot(cx, cy), hypot(size.width - cx, cy),
            hypot(cx, size.height - cy), hypot(size.width - cx, size.height - cy))
        return RadialGradient(
            stops: [
                .init(color: c.color, location: start),
                .init(color: fadeOut(c), location: 1),
            ],
            center: centre,
            startRadius: 0,
            endRadius: max(farthest * end, 1))
    }

    /// `--zen-grainy-background-opacity` + `mix-blend-mode: hard-light`.
    /// We have no grain-bg.png asset, so the noise is generated at runtime;
    /// SwiftUI has no hard-light blend mode, so `.overlay` is the nearest
    /// equivalent (it is hard-light with the layers swapped).
    @ViewBuilder
    private var grain: some View {
        if theme.texture > 0 {
            ZenGrainView()
                .opacity(theme.texture * 0.5)
                .blendMode(.overlay)
                .allowsHitTesting(false)
        }
    }
}

/// Procedural film grain, tiled from a small generated noise image so we are
/// not shipping (or decoding) a bitmap.
struct ZenGrainView: View {
    private static let tile: UIImage = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0..<(side * side) {
            // xorshift — deterministic, so the grain does not crawl between frames.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            let v = UInt8(truncatingIfNeeded: seed >> 24)
            pixels[i * 4 + 0] = v
            pixels[i * 4 + 1] = v
            pixels[i * 4 + 2] = v
            pixels[i * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }()

    var body: some View {
        Image(uiImage: Self.tile)
            .resizable(resizingMode: .tile)
    }
}
