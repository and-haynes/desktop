//  CompactPill.swift
//  The collapsed URL bar (#008AF).
//
//  A bare pill, nothing in it — not even the favicon or the domain. Andy's
//  call (#008CD): the point of compact mode is the page, and a label here is
//  still a label. It is what scrolling brings back, sized to be an obvious
//  target without reading as content.
//
//  Tapping it is the only thing that expands the bar. It carries the same
//  swipe-to-the-sidebar gesture the full bar has, so the drawer is reachable
//  without going through the expanded state first.

import SwiftUI

struct CompactPill: View {
    @ObservedObject var state: BrowserState
    /// Tapping expands the bar; the omnibox is one further tap, on the
    /// expanded bar's URL area.
    let onTap: () -> Void
    @Environment(\.zenPalette) private var palette

    private var tab: Tab? { state.activeTab }

    /// Spoken, never shown — VoiceOver still needs to know where a blank
    /// pill will take you.
    private var accessibilityDescription: String {
        guard let tab, !tab.isNewTabPage else { return "New Tab" }
        let host = URLDetector.prettyHost(tab.url)
        return host.isEmpty ? tab.url.absoluteString : host
    }

    var body: some View {
        Color.clear
            .frame(width: ZenMetrics.compactPillMinWidth, height: ZenMetrics.compactPillHeight)
            .contentShape(Capsule())
            .zenSurface(palette, radius: ZenMetrics.compactPillHeight / 2, elevated: true)
            .onTapGesture { onTap() }
            .simultaneousGesture(sidebarSwipe)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("compactPill")
            .accessibilityLabel("Show toolbar — \(accessibilityDescription)")
            .accessibilityAddTraits(.isButton)
    }

    /// The same table the full bar uses (`BarSwipeGesture`), so up opens the
    /// drawer from the pill exactly as it does from the bar, and the
    /// sidebar-edge setting mirrors right/left for both.
    private var sidebarSwipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { _ in Haptics.shared.prepare(.sidebarSnap) }
            .onEnded { value in
                let action = BarSwipeGesture.action(
                    translation: value.translation, velocity: value.velocity,
                    isSidebarOpen: state.isSidebarVisible,
                    mapping: state.display.sidebarEdge.swipeMapping)
                guard action != .none else { return }
                Haptics.shared.fire(.sidebarSnap)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    state.isSidebarVisible = action == .openSidebar
                }
            }
    }
}
