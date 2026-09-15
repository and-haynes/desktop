//  ZenPalette.swift
//  The derived token set from src/zen/common/styles/zen-theme.css.
//
//  Upstream declares every colour as a `color-mix()` of `--zen-primary-color`
//  (the space accent) against `--zen-branding-bg` under `light-dark()`. This is
//  a line-by-line port so that a given accent produces the same palette on iOS
//  as it does in the desktop browser.

import Foundation
import SwiftUI

/// Literal constants from zen-theme.css that are not derived from the accent.
enum ZenTokens {
    /// `--zen-border-radius: 7px`
    static let borderRadius: CGFloat = 7
    /// `--zen-squircle-value: 1.3` — SwiftUI has no superellipse corner shape,
    /// so we approximate with `.continuous` rounded rectangles throughout.
    static let squircle: CGFloat = 1.3
    /// `--zen-branding-dark: #101010`
    static let brandingDark = ZenColor(hex: "#101010")!
    /// `--zen-branding-paper: #e2e2e2`
    static let brandingPaper = ZenColor(hex: "#e2e2e2")!
    /// `--zen-workspace-indicator-height: 44px` (38px when collapsed)
    static let spaceIndicatorHeight: CGFloat = 44
    static let spaceIndicatorHeightCollapsed: CGFloat = 38
    /// `--zen-toolbar-height` — 42px on macOS; iOS wants a thumb-sized target.
    static let toolbarHeight: CGFloat = 44
    /// `--zen-active-tab-scale: 0.985`
    static let activeTabScale: CGFloat = 0.985
    /// `--zen-big-shadow: rgba(0, 0, 0, 0.24) 0px 3px 8px`
    static let bigShadowColor = ZenColor(r: 0, g: 0, b: 0, a: 0.24)
    static let bigShadowRadius: CGFloat = 8
    static let bigShadowY: CGFloat = 3
    /// `--zen-hidden-toolbar-transition-duration: 0.15s`
    static let hiddenToolbarTransition: Double = 0.15

    /// Zen's own default accent, used before a space picks one.
    static let defaultAccent = ZenColor(hex: "#5B6EE1")!

    /// Sepia's branding pair. Not a Zen token — upstream has two schemes, not
    /// three — but chosen the same way theirs are: one paper colour and one ink
    /// colour, with every other token mixed out of them by the same chain.
    static let sepiaPaper = ZenColor(hex: "#F4ECD8")!
    static let sepiaInk = ZenColor(hex: "#5B4636")!

    /// The amber the URL pill's warning badge and the stern certificate prompt
    /// share. Deliberately not red: most of what it marks — plain HTTP on a
    /// home network, a self-signed box — is a *caveat*, not an incident, and
    /// red for a caveat is how people learn to ignore red.
    static let warningColor = ZenColor(hex: "#E0922F")!
}

/// The base a palette is derived against: the branding pair, plus the handful
/// of surface colours zen-theme.css hard-codes per scheme rather than mixing.
///
/// Upstream has two of these, expressed as `light-dark()`. Sepia is a third,
/// and it is *only* a different base — every token below is mixed by exactly
/// the same chain, so a sepia palette is as internally consistent as a light
/// one and no call site has to know it exists.
enum ZenSurfaceBase: String, Equatable, Sendable {
    case light
    case dark
    case sepia

    /// Sepia is a light scheme with warm paper: every readability decision that
    /// asks "is this dark?" wants the light answer.
    var isDark: Bool { self == .dark }

    /// `--zen-branding-bg`
    var bg: ZenColor {
        switch self {
        case .light: return ZenTokens.brandingPaper
        case .dark: return ZenTokens.brandingDark
        case .sepia: return ZenTokens.sepiaPaper
        }
    }

    /// `--zen-branding-bg-reverse`
    var bgReverse: ZenColor {
        switch self {
        case .light: return ZenTokens.brandingDark
        case .dark: return ZenTokens.brandingPaper
        case .sepia: return ZenTokens.sepiaInk
        }
    }

    /// What the light-scheme mixes reach for when they lighten. `white` on a
    /// grey scheme; on paper, white would bleach the warmth straight back out.
    var lift: ZenColor {
        switch self {
        case .light: return .white
        case .dark: return bg
        case .sepia: return ZenTokens.sepiaPaper.mix(.white, weight: 0.35)
        }
    }

    /// …and when they darken.
    var shade: ZenColor {
        switch self {
        case .light: return .black
        case .dark: return .black
        case .sepia: return ZenTokens.sepiaInk
        }
    }

    /// `--zen-dialog-background: light-dark(#fafbff, #1c1c1c)`
    var dialogBackground: ZenColor {
        switch self {
        case .light: return ZenColor(hex: "#fafbff")!
        case .dark: return ZenColor(hex: "#1c1c1c")!
        case .sepia: return ZenTokens.sepiaPaper.mix(.white, weight: 0.55)
        }
    }

    /// The base `--zen-urlbar-background` is mixed against.
    var urlbarBase: ZenColor {
        switch self {
        case .light: return ZenColor(hex: "#f4f4f4")!
        case .dark: return ZenColor(24, 24, 24)
        case .sepia: return ZenTokens.sepiaPaper.mix(.white, weight: 0.72)
        }
    }

    /// `--zen-main-browser-background: light-dark(rgb(235,235,235), #1b1b1b)`
    var mainBrowserBackground: ZenColor {
        switch self {
        case .light: return ZenColor(235, 235, 235)
        case .dark: return ZenColor(hex: "#1b1b1b")!
        case .sepia: return ZenTokens.sepiaPaper.mix(.white, weight: 0.88)
        }
    }

    /// `--zen-themed-toolbar-bg-transparent: light-dark(branding-bg, #171717)`
    var themedToolbarBG: ZenColor {
        switch self {
        case .light: return bg
        case .dark: return ZenColor(hex: "#171717")!
        case .sepia: return bg
        }
    }
}

/// Every colour token zen-theme.css exposes, resolved for one accent in one
/// colour scheme.
struct ZenPalette: Equatable {
    let accent: ZenColor
    let base: ZenSurfaceBase
    let isDark: Bool
    /// True for the warm-paper scheme. Only the page-tint user script and the
    /// background wash need to know; every colour token is already correct.
    var isSepia: Bool { base == .sepia }

    // MARK: Branding
    /// `--zen-branding-bg`
    let brandingBG: ZenColor
    /// `--zen-branding-bg-reverse`
    let brandingBGReverse: ZenColor

    // MARK: Derived colour ramp
    /// `--zen-colors-primary`
    let primary: ZenColor
    /// `--zen-colors-secondary`
    let secondary: ZenColor
    /// `--zen-colors-tertiary`
    let tertiary: ZenColor
    /// `--zen-colors-hover-bg`
    let hoverBG: ZenColor
    /// `--zen-colors-primary-foreground`
    let primaryForeground: ZenColor
    /// `--zen-colors-border`
    let border: ZenColor
    /// `--zen-colors-border-contrast`
    let borderContrast: ZenColor
    /// `--zen-colors-input-bg`
    let inputBG: ZenColor

    // MARK: Surfaces
    /// `--zen-dialog-background`
    let dialogBackground: ZenColor
    /// `--zen-urlbar-background`
    let urlbarBackground: ZenColor
    /// `--zen-main-browser-background`
    let mainBrowserBackground: ZenColor
    /// `--zen-themed-toolbar-bg-transparent`
    let themedToolbarBG: ZenColor
    /// `--zen-sidebar-notification-bg`
    let sidebarNotificationBG: ZenColor
    /// `--zen-toolbar-element-bg-hover`
    let toolbarElementHoverBG: ZenColor
    /// `--zen-sidebar-themed-icon-fill`
    let sidebarIconFill: ZenColor

    /// Body text colour. Not a zen-theme.css token as such — upstream inherits
    /// `--toolbox-textcolor` from the scheme includes, which resolve to the
    /// reversed branding colour at 90%.
    let text: ZenColor
    /// Secondary/dimmed label colour.
    let textSecondary: ZenColor

    init(accent: ZenColor, isDark: Bool) {
        self.init(accent: accent, base: isDark ? .dark : .light)
    }

    init(accent: ZenColor, base: ZenSurfaceBase) {
        self.accent = accent
        self.base = base
        let isDark = base.isDark
        self.isDark = isDark

        let bg = base.bg
        let bgReverse = base.bgReverse
        // Where the light chain reaches for white or black, a warm base reaches
        // for its own paper and ink — otherwise every mix bleaches the warmth
        // straight back out and sepia is just light with a tinted sidebar.
        let lift = base.lift
        let shade = base.shade
        brandingBG = bg
        brandingBGReverse = bgReverse

        // --zen-colors-primary
        //   light: color-mix(in srgb, accent 50%, black 50%)
        //   dark:  color-mix(in srgb, accent 20%, branding-bg 80%)
        let primary =
            isDark
            ? accent.mix(bg, weight: 0.20)
            : accent.mix(shade, weight: 0.50)
        self.primary = primary

        // --zen-colors-secondary
        //   light: color-mix(in srgb, primary 20%, white 80%)
        //   dark:  color-mix(in srgb, accent 30%, branding-bg 70%)
        let secondary =
            isDark
            ? accent.mix(bg, weight: 0.30)
            : primary.mix(lift, weight: 0.20)
        self.secondary = secondary

        // --zen-colors-tertiary
        //   light: color-mix(in srgb, accent 2%, white 98%)
        //   dark:  color-mix(in srgb, accent 1%, branding-bg 99%)
        let tertiary =
            isDark
            ? accent.mix(bg, weight: 0.01)
            : accent.mix(lift, weight: 0.02)
        self.tertiary = tertiary

        // --zen-colors-hover-bg
        //   light: color-mix(in srgb, accent 90%, white 10%)
        //   dark:  color-mix(in srgb, accent 90%, branding-bg 10%)
        hoverBG = isDark ? accent.mix(bg, weight: 0.90) : accent.mix(lift, weight: 0.90)

        // --zen-colors-primary-foreground
        //   light: branding-bg-reverse
        //   dark:  color-mix(in srgb, accent 80%, white 20%)
        primaryForeground = isDark ? accent.mix(lift, weight: 0.80) : bgReverse

        // --zen-colors-border
        //   light: color-mix(in srgb, secondary 50%, transparent)
        //   dark:  color-mix(in srgb, secondary 20%, rgb(79, 79, 79))
        border =
            isDark
            ? secondary.mix(ZenColor(79, 79, 79), weight: 0.20)
            : secondary.mix(.transparent, weight: 0.50)

        // --zen-colors-border-contrast
        //   light: color-mix(in srgb, secondary 10%, rgba(181,181,181,.11) 90%)
        //   dark:  color-mix(in srgb, secondary 10%, rgba(255,255,255,.11) 90%)
        borderContrast =
            isDark
            ? secondary.mix(ZenColor(255, 255, 255, 0.11), weight: 0.10)
            : secondary.mix(ZenColor(181, 181, 181, 0.11), weight: 0.10)

        // --zen-colors-input-bg
        //   light: color-mix(in srgb, accent 1%, tertiary 99%)
        //   dark:  color-mix(in srgb, accent 1%, branding-bg 99%)
        inputBG =
            isDark
            ? accent.mix(bg, weight: 0.01)
            : accent.mix(tertiary, weight: 0.01)

        // --zen-dialog-background: light-dark(#fafbff, #1c1c1c)
        dialogBackground = base.dialogBackground

        // --zen-urlbar-background
        //   light: color-mix(in srgb, accent 3%, #f4f4f4 97%)
        //   dark:  color-mix(in srgb, accent 4%, rgb(24,24,24) 96%)
        urlbarBackground =
            isDark
            ? accent.mix(base.urlbarBase, weight: 0.04)
            : accent.mix(base.urlbarBase, weight: 0.03)

        // --zen-main-browser-background: light-dark(rgb(235,235,235), #1b1b1b)
        mainBrowserBackground = base.mainBrowserBackground

        // --zen-themed-toolbar-bg-transparent: light-dark(branding-bg, #171717)
        themedToolbarBG = base.themedToolbarBG

        // --zen-sidebar-notification-bg:
        //   color-mix(in srgb, accent 5%, light-dark(white, black))
        sidebarNotificationBG = accent.mix(isDark ? .black : lift, weight: 0.05)

        // --zen-toolbar-element-bg-hover:
        //   light-dark(rgba(0,0,0,.08), rgba(255,255,255,.1))
        toolbarElementHoverBG =
            isDark
            ? ZenColor(r: 1, g: 1, b: 1, a: 0.10)
            : bgReverse.withAlpha(base == .sepia ? 0.10 : 0.08)

        // --zen-sidebar-themed-icon-fill
        //   light: color-mix(in srgb, accent 50%, black)
        //   dark:  color-mix(in srgb, colors-primary 15%, #ebebeb)
        sidebarIconFill =
            isDark
            ? primary.mix(ZenColor(hex: "#ebebeb")!, weight: 0.15)
            : accent.mix(shade, weight: 0.50)

        text = bgReverse.withAlpha(0.92)
        textSecondary = bgReverse.withAlpha(0.55)
    }
}
