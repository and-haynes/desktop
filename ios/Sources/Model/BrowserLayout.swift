//  BrowserLayout.swift
//  How much of the screen the page gets.
//
//  Zen's desktop chrome always frames the content — the browser view sits
//  inset from the window edge by `--zen-element-separation` so the space's
//  gradient shows around it. On a phone that framing costs real estate you
//  notice, so the layout is a three-state cycle rather than a fixed choice:
//  keep the frame, drop it, or let the page have the whole screen and float
//  the controls over it.

import Foundation

enum BrowserLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The page inset in a rounded card, the space gradient framing it, and a
    /// persistent bottom bar below. Zen's desktop proportions.
    case card
    /// The page fills the width and runs up under the status bar, so its own
    /// chrome scrolls beneath the clock. The bottom bar stays put.
    case edgeToEdge
    /// The page owns every pixel; the bar floats over it with no backing
    /// material, so the page shows through.
    case fullScreen

    var id: String { rawValue }

    /// The next state in the cycle, wrapping. Declaration order *is* the cycle
    /// order, so the two cannot drift apart.
    var next: BrowserLayout {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    var displayName: String {
        switch self {
        case .card: return "Card"
        case .edgeToEdge: return "Edge to Edge"
        case .fullScreen: return "Full Screen"
        }
    }

    var symbol: String {
        switch self {
        case .card: return "rectangle.inset.filled"
        case .edgeToEdge: return "rectangle.portrait.arrowtriangle.2.outward"
        case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        }
    }

    /// Whether the page is inset from the screen edges and rounded.
    var framesContent: Bool { self == .card }

    /// Whether the page runs up under the status bar.
    var ignoresTopSafeArea: Bool { self != .card }

    /// Whether the bar sits *over* the page rather than below it. Only the
    /// floating bar drops its background material.
    var barFloats: Bool { self == .fullScreen }
}
