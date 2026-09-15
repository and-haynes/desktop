//  Space.swift
//  Port of the workspace record `#createWorkspaceData()` builds upstream.
//
//  On desktop a space carries a `containerTabId` — a Firefox contextual
//  identity — and *that* is what isolates cookies and storage. WebKit has no
//  containers, but iOS 17 added `WKWebsiteDataStore(forIdentifier:)`, which
//  gives each store its own cookie jar, local storage and cache. We give every
//  space its own store UUID, so the isolation is strictly stronger than
//  upstream's default (where several spaces may share container 0).

import Foundation

struct Space: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    /// An emoji (upstream opens a full emoji picker) or an SF Symbol name.
    /// `isSymbol` disambiguates, mirroring upstream's `icon.endsWith(".svg")`.
    var icon: String
    var isSymbol: Bool = false
    var theme: ZenTheme = .default
    /// Identifier for this space's `WKWebsiteDataStore`. Separate from `id` so
    /// that deleting and recreating a space can deliberately reuse or discard
    /// its cookie jar.
    var dataStoreID: UUID = UUID()

    init(
        name: String, icon: String, isSymbol: Bool = false, theme: ZenTheme = .default,
        id: UUID = UUID()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isSymbol = isSymbol
        self.theme = theme
    }

    /// `--zen-primary-color` for this space.
    func accent(isDark: Bool) -> ZenColor { theme.accentColor(isDark: isDark) }

    func palette(systemDark: Bool) -> ZenPalette {
        // A themed space overrides the system scheme with whichever text colour
        // actually contrasts (`shouldBeDarkMode`); an unthemed one follows it.
        let dark = theme.forcedDarkMode ?? systemDark
        return ZenPalette(accent: accent(isDark: dark), isDark: dark)
    }

    /// The set a fresh install starts with — enough to show what spaces are for
    /// without pretending to know the owner's life.
    static func starterSpaces() -> [Space] {
        [
            Space(
                name: "Personal", icon: "house.fill", isSymbol: true,
                theme: ZenGradientGenerator.theme(
                    seed: ZenColor(hueDegrees: 265, saturation: 95, lightness: 62),
                    harmony: .analogous)),
            Space(
                name: "Work", icon: "briefcase.fill", isSymbol: true,
                theme: ZenGradientGenerator.theme(
                    seed: ZenColor(hueDegrees: 200, saturation: 95, lightness: 55),
                    harmony: .analogous)),
        ]
    }

    /// Focus mode's own space. Purple, as Firefox Focus is, so there is never
    /// a question about which mode you are in. Created fresh on every entry —
    /// its `dataStoreID` is what backs the ephemeral WebKit store, so a new id
    /// is a new cookie jar.
    static func focusSpace() -> Space {
        Space(
            name: "Focus", icon: "eye.slash.fill", isSymbol: true,
            theme: ZenGradientGenerator.theme(
                seed: ZenColor(hueDegrees: 282, saturation: 96, lightness: 58),
                harmony: .singleAnalogous))
    }

    /// Icons offered by the space editor when the owner does not want an emoji.
    static let symbolChoices: [String] = [
        "house.fill", "briefcase.fill", "book.fill", "cart.fill", "heart.fill",
        "star.fill", "bolt.fill", "leaf.fill", "flame.fill", "gamecontroller.fill",
        "music.note", "camera.fill", "paintbrush.fill", "hammer.fill", "graduationcap.fill",
        "airplane", "figure.run", "brain.head.profile", "chart.line.uptrend.xyaxis", "globe",
    ]
}
