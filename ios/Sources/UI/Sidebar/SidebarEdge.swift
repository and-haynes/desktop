//  SidebarEdge.swift
//  Which side the vertical tab sidebar lives on — Zen desktop's own choice
//  (`sidebar.position`), mirrored here. A pure enum plus the small layout and
//  gesture math RootView and OmniboxPill need, kept separate so it is
//  testable without a simulator.

import SwiftUI

enum SidebarEdge: String, Codable, CaseIterable, Identifiable, Sendable {
    case leading
    case trailing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leading: return "Left"
        case .trailing: return "Right"
        }
    }

    // MARK: Layout

    /// Which side of a `ZStack`/`HStack` the drawer or the persistent sidebar
    /// occupies.
    var alignment: Alignment {
        switch self {
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    /// The edge a slide-in transition or an edge-swipe reveal comes from.
    var swiftUIEdge: Edge {
        switch self {
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    /// The SF Symbol the toolbar's sidebar toggle should draw — `sidebar.leading`
    /// and `sidebar.trailing` both exist so the glyph can point at the edge it
    /// actually opens.
    var toggleSymbolName: String {
        switch self {
        case .leading: return "sidebar.leading"
        case .trailing: return "sidebar.trailing"
        }
    }

    // MARK: Gestures

    /// `BarSwipeGesture`'s direction → action table, mirrored so the URL bar
    /// still "swipes toward the drawer" wherever the drawer actually is. Up
    /// and down are unaffected by the edge — only the horizontal pair
    /// inverts, since swiping toward the sidebar's edge is what should open
    /// it.
    var swipeMapping: [BarSwipeDirection: BarGestureAction] {
        switch self {
        case .leading:
            return BarSwipeGesture.defaultMapping
        case .trailing:
            return [
                .left: .openSidebar,
                .up: .openSidebar,
                .right: .closeSidebar,
                .down: .closeSidebar,
            ]
        }
    }
}
