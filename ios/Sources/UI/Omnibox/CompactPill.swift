//  CompactPill.swift
//  The collapsed URL bar (#008AF).
//
//  Where you are, and nothing else: a favicon and a domain in a capsule that
//  hugs its own text, so most of the bar's width goes back to the page. It is
//  what scrolling brings back — a full toolbar for every flick is exactly the
//  noise compact mode is supposed to remove.
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

    private var label: String {
        guard let tab, !tab.isNewTabPage else { return "New Tab" }
        let host = URLDetector.prettyHost(tab.url)
        return host.isEmpty ? tab.url.absoluteString : host
    }

    var body: some View {
        HStack(spacing: 7) {
            if let tab {
                FaviconView(tab: tab, size: 15)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.text.withAlpha(0.6).color)
            }
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.text.color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .frame(height: ZenMetrics.compactPillHeight)
        // Never so wide that it stops being a pill.
        .frame(maxWidth: ZenMetrics.compactPillMaxWidth)
        .fixedSize(horizontal: true, vertical: false)
        .zenSurface(palette, radius: ZenMetrics.compactPillHeight / 2, elevated: true)
        .contentShape(Capsule())
        .onTapGesture { onTap() }
        .simultaneousGesture(sidebarSwipe)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("compactPill")
        .accessibilityLabel("Show toolbar — \(label)")
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
