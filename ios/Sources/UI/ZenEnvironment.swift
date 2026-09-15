//  ZenEnvironment.swift
//  Palette propagation and the small shared views the chrome is built from.

import SwiftUI

private struct ZenPaletteKey: EnvironmentKey {
    static let defaultValue = ZenPalette(accent: ZenTokens.defaultAccent, isDark: true)
}

extension EnvironmentValues {
    var zenPalette: ZenPalette {
        get { self[ZenPaletteKey.self] }
        set { self[ZenPaletteKey.self] = newValue }
    }
}

/// A favicon with Zen's fallbacks: the real icon if we have one, otherwise a
/// monogram on a disc tinted from the accent — upstream does the same
/// (`color-mix(in srgb, var(--zen-primary-color) 80%, black/white)` at 0.5).
struct FaviconView: View {
    let tab: Tab
    var size: CGFloat = ZenMetrics.faviconSize
    @Environment(\.zenPalette) private var palette

    var body: some View {
        Group {
            if let data = tab.faviconData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if tab.isNewTabPage {
                Image(systemName: "plus")
                    .font(.system(size: size * 0.62, weight: .semibold))
                    .foregroundStyle(palette.text.color)
            } else {
                ZStack {
                    palette.accent.mix(palette.isDark ? .black : .white, weight: 0.8)
                        .withAlpha(0.5).color
                    Text(tab.monogram)
                        .font(.system(size: size * 0.58, weight: .semibold))
                        .foregroundStyle(palette.text.color)
                }
            }
        }
        .frame(width: size, height: size)
        // `.tab-icon-image { border-radius: 4px }`
        .clipShape(RoundedRectangle(cornerRadius: ZenMetrics.faviconRadius, style: .continuous))
        // Zen has no bespoke discarded-tab styling, but on a phone the
        // distinction between a live tab and a stub is worth showing.
        .opacity(tab.isLoaded ? 1 : 0.62)
        .saturation(tab.isLoaded ? 1 : 0.35)
    }
}

/// A space's icon: an SF Symbol or an emoji, matching upstream's
/// `icon.endsWith(".svg")` split between an <img> and emoji text.
struct SpaceIconView: View {
    let space: Space
    var size: CGFloat = 15

    var body: some View {
        if space.isSymbol {
            Image(systemName: space.icon)
                .font(.system(size: size, weight: .medium))
        } else {
            Text(space.icon)
                .font(.system(size: size))
        }
    }
}

/// The glassy chrome surface the sidebar, omnibox and glance card all sit on.
struct ZenSurface: ViewModifier {
    let palette: ZenPalette
    var radius: CGFloat = ZenMetrics.rowRadius
    var elevated: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(palette.urlbarBackground.withAlpha(0.55).color)
                    }
            }
            .overlay {
                // `outline: 0.5px solid light-dark(rgba(0,0,0,.2), rgba(255,255,255,.2))`
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(palette.borderContrast.color, lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(
                color: elevated
                    ? ZenColor(r: 0, g: 0, b: 0, a: palette.isDark ? 0.6 : 0.35).color
                    : .clear,
                radius: elevated ? ZenMetrics.omniboxShadowRadius : 0,
                y: elevated ? ZenMetrics.omniboxShadowY : 0)
    }
}

extension View {
    func zenSurface(_ palette: ZenPalette, radius: CGFloat = ZenMetrics.rowRadius, elevated: Bool = false)
        -> some View
    {
        modifier(ZenSurface(palette: palette, radius: radius, elevated: elevated))
    }

    /// Zen's `--zen-big-shadow: rgba(0,0,0,0.24) 0 3px 8px`.
    func zenBigShadow() -> some View {
        shadow(
            color: ZenTokens.bigShadowColor.color, radius: ZenTokens.bigShadowRadius,
            y: ZenTokens.bigShadowY)
    }
}

/// A round chrome button, as used by the glance controls and the sidebar
/// footer (`border-radius: 999px`, hover scale 1.02, active 0.98).
struct ZenCircleButton: View {
    let symbol: String
    var size: CGFloat = ZenMetrics.glanceButtonSize
    var tint: Color?
    let action: () -> Void
    @Environment(\.zenPalette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(tint == nil ? palette.text.color : .white)
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(tint ?? palette.themedToolbarBG.mix(palette.accent, weight: 0.96).color)
                }
                .overlay { Circle().strokeBorder(palette.borderContrast.color, lineWidth: 0.5) }
                // `box-shadow: 0 0 12px 1px rgba(0,0,0,0.07)`
                .shadow(color: .black.opacity(0.18), radius: 6, y: 1)
        }
        .buttonStyle(ZenPressStyle())
    }
}

/// `:active { scale: 0.98 }`
struct ZenPressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - The floating bar's backing (#00891)

/// `GlassEffectContainer` is what lets neighbouring glass elements blend into
/// one another instead of stacking two separate lenses — the find bar and the
/// URL bar sit 8pt apart and should read as one piece of glass. A no-op below
/// iOS 26, where there is no Liquid Glass to contain.
struct ZenGlassContainer<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// Puts the chosen backing behind a bar. `transparent` is the only one that
/// still depends on context: a floating bar gets an outline and glyph shadows
/// (which is what the full-screen layout shipped with), and a bar in the
/// layout flow keeps Zen's ordinary chrome surface.
struct ZenBarFill: ViewModifier {
    let fill: BarFill
    let palette: ZenPalette
    var isFloating: Bool = true
    var radius: CGFloat = ZenMetrics.rowRadius
    /// Glass that can be tapped should respond to the touch; glass that is
    /// only a backdrop should not.
    var isInteractive: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        switch fill {
        case .liquidGlass:
            glass(content)
        case .matte:
            matte(content)
        case .transparent:
            transparent(content)
        }
    }

    /// Light enough that the page still refracts through the lens, heavy
    /// enough that the palette's glyph colour keeps its contrast whatever is
    /// behind it.
    private var glassTint: Color { palette.urlbarBackground.withAlpha(0.5).color }

    @ViewBuilder
    private func glass(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Tinted with the chrome surface rather than left plain: Liquid
            // Glass takes its lightness from whatever is behind it, and the
            // bar's glyphs are coloured from the *space palette*, which does
            // not move. Untinted, a dark-themed space over a white page put
            // near-white glyphs on a near-white lens.
            content
                .glassEffect(
                    isInteractive
                        ? Glass.regular.tint(glassTint).interactive()
                        : Glass.regular.tint(glassTint),
                    in: Capsule())
        } else {
            // No Liquid Glass below iOS 26. The honest substitute is the
            // material the sidebar and the omnibox box already use, in the same
            // capsule, so the choice still changes the bar's shape and weight.
            content
                .background { Capsule().fill(.ultraThinMaterial) }
                .overlay {
                    Capsule().fill(palette.urlbarBackground.withAlpha(0.45).color)
                        .allowsHitTesting(false)
                }
                .overlay {
                    Capsule().strokeBorder(palette.borderContrast.color, lineWidth: 0.5)
                }
                .clipShape(Capsule())
                .shadow(color: .black.opacity(palette.isDark ? 0.5 : 0.28), radius: 10, y: 3)
        }
    }

    private func matte(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            // Opaque: `urlbarBackground` carries alpha for the frosted look, so
            // it is composited over the chrome base first. The page must not
            // show through at all — that is the whole point of Matte.
            .background { shape.fill(palette.mainBrowserBackground.color) }
            .background { shape.fill(palette.urlbarBackground.color) }
            .overlay { shape.strokeBorder(palette.borderContrast.color, lineWidth: 0.5) }
            .clipShape(shape)
            .shadow(color: .black.opacity(palette.isDark ? 0.5 : 0.3), radius: 10, y: 3)
    }

    @ViewBuilder
    private func transparent(_ content: Content) -> some View {
        if isFloating {
            content
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(palette.text.withAlpha(0.28).color, lineWidth: 0.5)
                }
                // The page behind can be any colour, so the glyphs get their
                // own shadow rather than relying on a backdrop.
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        } else {
            content.zenSurface(palette, radius: radius, elevated: true)
        }
    }
}

extension View {
    func zenBarFill(
        _ fill: BarFill, palette: ZenPalette, isFloating: Bool = true,
        radius: CGFloat = ZenMetrics.rowRadius, isInteractive: Bool = true
    ) -> some View {
        modifier(
            ZenBarFill(
                fill: fill, palette: palette, isFloating: isFloating, radius: radius,
                isInteractive: isInteractive))
    }
}
