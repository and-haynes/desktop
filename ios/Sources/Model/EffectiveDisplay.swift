//  EffectiveDisplay.swift
//  What the chrome should look like *right now*, from the globals and the
//  active space's overrides (#008BB).
//
//  Zen's whole premise is that a space is a context: Work and Personal are
//  different places, and the browser looks different in each. Up to now that
//  was true of the colours and nothing else — the layout, the appearance, the
//  bar and compact mode were one global set, so a space that wanted a docked
//  bar and a dark scheme had to be switched to by hand, twice.
//
//  ## One accessor, and why it is enforced
//
//  The failure mode of a feature like this is not a bug you can see; it is a
//  *hole*. One view that still reads `settings.layout` directly keeps working
//  perfectly in the global case and silently ignores the override, and nobody
//  finds out until they wonder why one screen did not follow. So there is
//  exactly one way to ask — `BrowserState.display` — and
//  `EffectiveDisplayTests.testNothingReadsTheGlobalsDirectly` reads the source
//  tree and fails if any view outside the editors reaches past it.
//
//  ## Precedence
//
//  Per-field, and only two levels: the space's override if it has one, the
//  global otherwise. Deliberately not a chain — "inherit from the previous
//  space" or a per-tab layer would both be answers to questions nobody asked,
//  and each one doubles the number of states a bug can hide in.

import Foundation

/// A space's display choices. Every field is optional, and nil means inherit —
/// which is a different thing from "the same value as the global", because the
/// global can change afterwards and an inherited field has to follow it.
struct DisplayOverrides: Codable, Equatable, Sendable {
    var layout: BrowserLayout?
    var appearance: AppearanceMode?
    /// A named preset by id — the cheap way to say "this space uses the Safari
    /// bar" without copying a whole layout that then cannot follow the preset.
    var barPresetID: String?
    /// A whole layout of its own. Wins over `barPresetID`: it is the more
    /// specific answer, and the only way to say something no preset says.
    var barLayout: BarLayout?
    var barFill: BarFill?
    var compactModeEnabled: Bool?
    var sidebarEdge: SidebarEdge?
    /// The per-space default page zoom (#008B7's global, overridden).
    var textSize: Double?
    var navigationHelperEnabled: Bool?

    init() {}

    var isEmpty: Bool {
        layout == nil && appearance == nil && barPresetID == nil && barLayout == nil
            && barFill == nil && compactModeEnabled == nil && sidebarEdge == nil
            && textSize == nil && navigationHelperEnabled == nil
    }

    /// What the space editor and the Settings note list, in the order the
    /// editor shows them. A `[String]` rather than a set of flags because the
    /// only two consumers both want to *say* it.
    var overriddenNames: [String] {
        var names: [String] = []
        if layout != nil { names.append("Layout") }
        if appearance != nil { names.append("Appearance") }
        if barLayout != nil || barPresetID != nil { names.append("Bar layout") }
        if barFill != nil { names.append("Bar fill") }
        if compactModeEnabled != nil { names.append("Compact mode") }
        if sidebarEdge != nil { names.append("Sidebar position") }
        if textSize != nil { names.append("Text size") }
        if navigationHelperEnabled != nil { names.append("Navigation helper") }
        return names
    }

    private enum CodingKeys: String, CodingKey {
        case layout, appearance, barPresetID, barLayout, barFill
        case compactModeEnabled, sidebarEdge, textSize, navigationHelperEnabled
    }

    /// Every field decodes optionally *and* tolerantly: a space written by a
    /// newer build with a layout value this one does not know must come back
    /// as "inherit", not as a thrown error that loses the whole space.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try? c.decodeIfPresent(BrowserLayout.self, forKey: .layout)
        appearance = try? c.decodeIfPresent(AppearanceMode.self, forKey: .appearance)
        barPresetID = try? c.decodeIfPresent(String.self, forKey: .barPresetID)
        barLayout = try? c.decodeIfPresent(BarLayout.self, forKey: .barLayout)
        barFill = try? c.decodeIfPresent(BarFill.self, forKey: .barFill)
        compactModeEnabled = try? c.decodeIfPresent(Bool.self, forKey: .compactModeEnabled)
        sidebarEdge = try? c.decodeIfPresent(SidebarEdge.self, forKey: .sidebarEdge)
        textSize = (try? c.decodeIfPresent(Double.self, forKey: .textSize)).flatMap { value in
            value.map(PageZoom.clamp)
        }
        navigationHelperEnabled =
            try? c.decodeIfPresent(Bool.self, forKey: .navigationHelperEnabled)
    }
}

/// The answer. Every field is resolved — nothing here is optional, which is
/// the point: a view reading this cannot accidentally forget the fallback.
struct EffectiveDisplay: Equatable, Sendable {
    var layout: BrowserLayout
    var appearance: AppearanceMode
    var barLayout: BarLayout
    var barFill: BarFill
    var compactModeEnabled: Bool
    var sidebarEdge: SidebarEdge
    /// The default page zoom for a site with no opinion of its own.
    var textSize: Double
    var navigationHelperEnabled: Bool
    /// Already resolved from Automatic — see `navigationHelperSide` below.
    var navigationHelperSide: SidebarEdge

    /// The bar's backing, with the layout's own override applied. Here rather
    /// than at each call site so "the layout can pin a fill" is decided once.
    var resolvedBarFill: BarFill { barLayout.resolvedFill(default: barFill) }

    /// Does the page surface run under the top safe area?
    ///
    /// The *layout cycle* decides, and nothing else. Card frames the content,
    /// so the card starts below the safe area; edge-to-edge and full screen
    /// both hand the page the top band, and that is where
    /// `PageTopInsets.webTopContentInset` earns its keep — the page paints to
    /// the very top as it scrolls, while its content and its own
    /// `position: fixed` header start below the island rather than behind it.
    ///
    /// Emphatically *not* a function of `showStatusBar`. That was the #008A9
    /// bug, and the layout cycle is exactly where it is easiest to reintroduce
    /// — "the clock is gone, so take the space" is wrong, because the island
    /// is still there.
    var pageRunsUnderTopSafeArea: Bool { layout.ignoresTopSafeArea }

    static func resolve(
        settings: ZenSettings, overrides: DisplayOverrides?
    ) -> EffectiveDisplay {
        let sidebarEdge = overrides?.sidebarEdge ?? settings.sidebarEdge
        return EffectiveDisplay(
            layout: overrides?.layout ?? settings.layout,
            appearance: overrides?.appearance ?? settings.appearance,
            barLayout: resolveBarLayout(settings: settings, overrides: overrides),
            barFill: overrides?.barFill ?? settings.barFill,
            compactModeEnabled: overrides?.compactModeEnabled ?? settings.compactModeEnabled,
            sidebarEdge: sidebarEdge,
            textSize: PageZoom.clamp(overrides?.textSize ?? settings.defaultPageZoom),
            navigationHelperEnabled: overrides?.navigationHelperEnabled
                ?? settings.navigationHelperEnabled,
            // Automatic is the edge *opposite* the sidebar — and it follows
            // the sidebar edge this space actually resolved to, not the global
            // one, or a space that moved its sidebar would put the helper
            // under the same thumb.
            navigationHelperSide: settings.navigationHelperSide
                ?? (sidebarEdge == .leading ? .trailing : .leading))
    }

    /// A full layout beats a preset id beats the global. A preset id that
    /// names nothing — a preset deleted since, or a file from a build with
    /// presets this one does not have — falls through rather than leaving the
    /// space with no bar at all.
    private static func resolveBarLayout(
        settings: ZenSettings, overrides: DisplayOverrides?
    ) -> BarLayout {
        if let explicit = overrides?.barLayout { return explicit }
        if let preset = BarPreset.preset(id: overrides?.barPresetID) { return preset.layout }
        return settings.barLayout
    }
}
