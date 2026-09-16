//  ReaderSettings.swift
//  Everything the reader lets you change about how an article looks (#008BC).
//
//  Reader mode on a phone is not a toggle, it is a *reading environment*, and
//  the thing that makes one good is that it bends to the person rather than the
//  page. So this is a value type with a knob per decision — face, size, leading,
//  tracking, measure, alignment, colour, dimming, images, drop caps, and how
//  fast it reads aloud — and every one of them is clamped on the way in.
//
//  Two copies of it exist at any moment: the **global default**, which lives in
//  `ZenSettings` and is edited in Settings, and a **per-site override** in
//  `ReaderSiteStore`, keyed by registrable domain. Opening an article looks up
//  the second and falls back to the first, which is what makes "this one blog
//  is always too small" a thing you fix once.
//
//  Clamping is not defensive paranoia: these values go into CSS custom
//  properties, and a hand-edited JSON file with `fontSize: 4000` would render a
//  single letter per screen with no way back inside the app.

import Foundation

// MARK: - Faces

/// The type faces on offer.
///
/// **Nothing is bundled.** Every face here is already on an iOS device: the
/// four system families (`ui-serif` is New York, `-apple-system` is SF) plus
/// the book faces Apple ships and Apple Books itself offers. Vendoring a web
/// font would cost a megabyte, a licence review and a second rendering path,
/// and would buy a reader nothing they cannot already get — see the ticket.
enum ReaderFont: String, Codable, CaseIterable, Identifiable, Sendable {
    case systemSerif
    case systemSans
    case systemRounded
    case systemMono
    case newYork
    case georgia
    case palatino
    case charter
    case avenir

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemSerif: return "Serif"
        case .systemSans: return "Sans"
        case .systemRounded: return "Rounded"
        case .systemMono: return "Mono"
        case .newYork: return "New York"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .charter: return "Charter"
        case .avenir: return "Avenir"
        }
    }

    /// Whether a sample of this face should be drawn with a serif — used for
    /// the specimen row in the control panel.
    var isSerif: Bool {
        switch self {
        case .systemSerif, .newYork, .georgia, .palatino, .charter: return true
        default: return false
        }
    }

    /// The CSS stack. Each ends in a generic family so a face that is missing
    /// on some future device degrades to the right *kind* of type rather than
    /// to Times.
    var cssStack: String {
        switch self {
        case .systemSerif: return "ui-serif, 'New York', Georgia, serif"
        case .systemSans:
            return "-apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif"
        case .systemRounded: return "ui-rounded, 'SF Pro Rounded', -apple-system, sans-serif"
        case .systemMono: return "ui-monospace, 'SF Mono', Menlo, monospace"
        case .newYork: return "'New York', ui-serif, Georgia, serif"
        case .georgia: return "Georgia, 'Times New Roman', serif"
        case .palatino: return "Palatino, 'Palatino Linotype', 'Iowan Old Style', serif"
        case .charter: return "Charter, 'Iowan Old Style', Georgia, serif"
        case .avenir: return "'Avenir Next', Avenir, -apple-system, sans-serif"
        }
    }
}

// MARK: - Themes

enum ReaderTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case light
    case sepia
    case dark
    /// True black, for an OLED phone read in the dark. Distinct from `dark`
    /// on purpose: #000 saves power and stops the halo round a dark-grey card,
    /// and it is *too* contrasty for a lit room, which is why both exist.
    case black
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .dark: return "Dark"
        case .black: return "Black"
        case .custom: return "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .light: return "sun.max"
        case .sepia: return "book.closed"
        case .dark: return "moon"
        case .black: return "circle.fill"
        case .custom: return "paintpalette"
        }
    }
}

enum ReaderAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case justified

    var id: String { rawValue }
    var displayName: String { self == .left ? "Left" : "Justified" }
    var cssValue: String { self == .left ? "left" : "justify" }
}

// MARK: - The settings

struct ReaderSettings: Codable, Equatable, Sendable {

    // Ranges are the single source of truth for both the sliders and the
    // clamp, so a control can never offer a value the model then rejects.
    static let fontSizeRange: ClosedRange<Double> = 14...32
    static let lineHeightRange: ClosedRange<Double> = 1.2...2.2
    /// In em. Deliberately small either side of zero — tracking is the control
    /// people reach for last and ruin type with first.
    static let letterSpacingRange: ClosedRange<Double> = -0.03...0.12
    /// The measure, in CSS pixels. 300 is a narrow column on a phone, 760 is
    /// about as wide as text stays readable on an iPad.
    static let contentWidthRange: ClosedRange<Double> = 300...760
    /// Space between paragraphs, in em of the body size.
    static let paragraphSpacingRange: ClosedRange<Double> = 0.3...2.5
    /// The in-reader dim. Capped below 1 — a control that can black the screen
    /// out entirely leaves no way to find the control again.
    static let dimRange: ClosedRange<Double> = 0...0.75
    /// AVSpeechUtterance's own scale. 0.5 is `AVSpeechUtteranceDefaultSpeechRate`.
    static let speechRateRange: ClosedRange<Double> = 0.35...0.7

    /// The three presets the measure slider snaps to.
    static let narrowWidth: Double = 340
    static let mediumWidth: Double = 560
    static let wideWidth: Double = 720

    var font: ReaderFont = .systemSerif
    var fontSize: Double = 19
    var lineHeight: Double = 1.6
    var letterSpacing: Double = 0
    var contentWidth: Double = ReaderSettings.mediumWidth
    var paragraphSpacing: Double = 1.0
    var alignment: ReaderAlignment = .left
    /// Only meaningful when justified — unhyphenated justified text on a phone
    /// column is a field of rivers.
    var hyphenation: Bool = true
    var theme: ReaderTheme = .light
    var customBackground: ZenColor = ZenColor(hex: "#F4F1EA")!
    var customText: ZenColor = ZenColor(hex: "#2B2B2B")!
    var customLink: ZenColor = ZenColor(hex: "#1D6FB8")!
    var dim: Double = 0
    var showImages: Bool = true
    var dropCaps: Bool = false
    var speechRate: Double = 0.5

    init() {}

    /// Every numeric field into range, with a non-finite value falling back to
    /// the default rather than to the nearest bound — NaN has no nearest bound.
    func clamped() -> ReaderSettings {
        var copy = self
        let fallback = ReaderSettings()
        copy.fontSize = Self.clamp(fontSize, Self.fontSizeRange, fallback.fontSize)
        copy.lineHeight = Self.clamp(lineHeight, Self.lineHeightRange, fallback.lineHeight)
        copy.letterSpacing = Self.clamp(
            letterSpacing, Self.letterSpacingRange, fallback.letterSpacing)
        copy.contentWidth = Self.clamp(
            contentWidth, Self.contentWidthRange, fallback.contentWidth)
        copy.paragraphSpacing = Self.clamp(
            paragraphSpacing, Self.paragraphSpacingRange, fallback.paragraphSpacing)
        copy.dim = Self.clamp(dim, Self.dimRange, fallback.dim)
        copy.speechRate = Self.clamp(speechRate, Self.speechRateRange, fallback.speechRate)
        return copy
    }

    private static func clamp(
        _ value: Double, _ range: ClosedRange<Double>, _ fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// The palette this configuration renders in.
    var palette: ReaderPalette {
        ReaderPalette(
            theme: theme, customBackground: customBackground, customText: customText,
            customLink: customLink)
    }

    // Same reasoning as `ZenSettings`: the synthesized Decodable *throws* on a
    // missing key rather than taking the property's default, so every setting
    // added after a file was written would make that file undecodable — and a
    // reader settings file that fails to decode silently resets everyone's
    // per-site choices.
    private enum CodingKeys: String, CodingKey {
        case font, fontSize, lineHeight, letterSpacing, contentWidth, paragraphSpacing
        case alignment, hyphenation, theme, customBackground, customText, customLink
        case dim, showImages, dropCaps, speechRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReaderSettings()
        font = try c.decodeIfPresent(ReaderFont.self, forKey: .font) ?? d.font
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? d.lineHeight
        letterSpacing =
            try c.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? d.letterSpacing
        contentWidth = try c.decodeIfPresent(Double.self, forKey: .contentWidth) ?? d.contentWidth
        paragraphSpacing =
            try c.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? d.paragraphSpacing
        alignment = try c.decodeIfPresent(ReaderAlignment.self, forKey: .alignment) ?? d.alignment
        hyphenation = try c.decodeIfPresent(Bool.self, forKey: .hyphenation) ?? d.hyphenation
        theme = try c.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? d.theme
        customBackground =
            try c.decodeIfPresent(ZenColor.self, forKey: .customBackground) ?? d.customBackground
        customText = try c.decodeIfPresent(ZenColor.self, forKey: .customText) ?? d.customText
        customLink = try c.decodeIfPresent(ZenColor.self, forKey: .customLink) ?? d.customLink
        dim = try c.decodeIfPresent(Double.self, forKey: .dim) ?? d.dim
        showImages = try c.decodeIfPresent(Bool.self, forKey: .showImages) ?? d.showImages
        dropCaps = try c.decodeIfPresent(Bool.self, forKey: .dropCaps) ?? d.dropCaps
        speechRate = try c.decodeIfPresent(Double.self, forKey: .speechRate) ?? d.speechRate
    }
}

// MARK: - Derived colours

/// The five colours a reader page needs, derived from the theme.
///
/// Only `background`, `text` and `link` are ever chosen by hand; `secondary`
/// (the byline and the meta line) and `border` (rules, blockquote edges, table
/// lines) are *mixed* from those two, so a custom theme cannot produce a byline
/// that is invisible against its own background.
struct ReaderPalette: Equatable, Sendable {
    let background: ZenColor
    let text: ZenColor
    let secondary: ZenColor
    let link: ZenColor
    let border: ZenColor
    /// The wash behind the sentence being read aloud.
    let highlight: ZenColor
    /// Whether the chrome over this page should draw itself light-on-dark.
    let isDark: Bool

    init(
        theme: ReaderTheme, customBackground: ZenColor, customText: ZenColor,
        customLink: ZenColor
    ) {
        let base: (bg: ZenColor, fg: ZenColor, link: ZenColor)
        switch theme {
        case .light:
            base = (ZenColor(hex: "#FFFFFF")!, ZenColor(hex: "#1B1B1F")!, ZenColor(hex: "#0B57D0")!)
        case .sepia:
            base = (ZenColor(hex: "#F7ECD9")!, ZenColor(hex: "#4A3B29")!, ZenColor(hex: "#9A4A1E")!)
        case .dark:
            base = (ZenColor(hex: "#1C1C1E")!, ZenColor(hex: "#DCDCE0")!, ZenColor(hex: "#7FB0FF")!)
        case .black:
            base = (ZenColor(hex: "#000000")!, ZenColor(hex: "#C6C6CA")!, ZenColor(hex: "#6FA8FF")!)
        case .custom:
            base = (customBackground, customText, customLink)
        }
        background = base.bg
        text = base.fg
        link = base.link
        // Mixed toward the background rather than given a fixed alpha: an
        // opaque colour composites identically over any wallpaper, and the
        // reader page has no wallpaper behind it to blend with anyway.
        secondary = base.fg.mix(base.bg, weight: 0.58)
        border = base.fg.mix(base.bg, weight: 0.16)
        highlight = base.fg.mix(base.bg, weight: 0.14)
        // Decided from the *background*, which is the surface the chrome sits
        // on. A custom theme of pale text on a pale ground is a bad idea but a
        // legal one, and the toolbar should still be legible when it happens.
        isDark = !base.bg.isLight
    }
}
