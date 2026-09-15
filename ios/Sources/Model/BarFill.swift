//  BarFill.swift
//  What sits behind the floating URL bar.
//
//  Zen's desktop urlbar always has a surface under it. The full-screen layout
//  (#00887) floats ours over the page with nothing behind it at all, which
//  reads beautifully over a dark page and *disappears* over a light one — an
//  outline and four grey glyphs, and no bar (#00891). Rather than pick one
//  backing and lose the other look, the backing is a choice.

import Foundation

enum BarFill: String, Codable, CaseIterable, Identifiable, Sendable {
    /// iOS 26's Liquid Glass: a real lens over the page, so the bar has
    /// presence without hiding what is behind it. Falls back to the same
    /// `.ultraThinMaterial` the rest of the chrome uses on iOS 17–25.
    case liquidGlass
    /// An opaque Zen surface with the usual hairline border. The page stops at
    /// the bar; nothing shows through, nothing can wash it out.
    case matte
    /// Outline and glyph shadows only, letting the page run right under it.
    /// This is what the full-screen layout shipped with.
    case transparent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .matte: return "Matte"
        case .transparent: return "Transparent"
        }
    }

    var detail: String {
        switch self {
        case .liquidGlass:
            return
                "A lens over the page. Needs iOS 26 or later; below that the bar "
                + "uses the same frosted material as the rest of the chrome."
        case .matte:
            return "An opaque surface. The most legible over a busy page."
        case .transparent:
            return "Outline only, so the page runs right under the bar."
        }
    }

    /// Liquid Glass is capsule-shaped by design — it is how the material reads
    /// as a lens rather than as a panel — where the other two keep Zen's
    /// `--border-radius-medium` corners.
    var isCapsule: Bool { self == .liquidGlass }
}
