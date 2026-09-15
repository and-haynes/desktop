//  SplitContainer.swift
//  Two tabs side by side with a draggable divider.
//
//  Upstream (ZenViewSplitter) supports up to MAX_TABS = 4 panes in vsep / hsep
//  / grid arrangements, laid out as a binary tree of resizable nodes, with an
//  invisible drag strip sitting in the gap between panes and a 2px accent
//  outline on the focused pane. We ship the two-pane case; 3–4 panes are a
//  TODO (see README).
//
//  Orientation follows the space available: side-by-side when the window is
//  wide (iPad, landscape iPhone), stacked when it is tall.

import SwiftUI

struct SplitContainer<Pane: View>: View {
    let primaryID: UUID
    let secondaryID: UUID
    @ObservedObject var state: BrowserState
    @Environment(\.zenPalette) private var palette
    @ViewBuilder let pane: (UUID) -> Pane

    @GestureState private var dragDelta: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let horizontal = geo.size.width >= geo.size.height
            let total = horizontal ? geo.size.width : geo.size.height
            let fraction = clampedFraction(dragDelta: dragDelta, total: total)
            let primaryExtent = max(0, total * fraction - ZenMetrics.splitGap / 2)
            let secondaryExtent = max(0, total * (1 - fraction) - ZenMetrics.splitGap / 2)

            ZStack {
                if horizontal {
                    HStack(spacing: 0) {
                        paneView(primaryID).frame(width: primaryExtent)
                        Color.clear.frame(width: ZenMetrics.splitGap)
                        paneView(secondaryID).frame(width: secondaryExtent)
                    }
                } else {
                    VStack(spacing: 0) {
                        paneView(primaryID).frame(height: primaryExtent)
                        Color.clear.frame(height: ZenMetrics.splitGap)
                        paneView(secondaryID).frame(height: secondaryExtent)
                    }
                }
                divider(horizontal: horizontal, total: total, fraction: fraction)
            }
        }
    }

    /// `zen.splitView.min-resize-width` is 7% of the parent.
    private func clampedFraction(dragDelta: CGFloat, total: CGFloat) -> Double {
        guard total > 0 else { return state.splitFraction }
        let proposed = state.splitFraction + Double(dragDelta / total)
        return min(max(proposed, ZenMetrics.splitMinFraction), 1 - ZenMetrics.splitMinFraction)
    }

    /// The secondary pane gets its own URL bar. It follows compact behaviour —
    /// present while the page is scrolling, gone shortly after — so a split on
    /// a phone does not spend two bars' worth of height on chrome.
    @ViewBuilder
    private func paneView(_ id: UUID) -> some View {
        let isFocused = id == state.activeTabID
        let showsOwnBar = id == secondaryID && !secondaryBarHidden
        VStack(spacing: 4) {
            if showsOwnBar {
                ZenGlassContainer(spacing: 4) {
                    // The pane bar follows the same `BarLayout` as the main one
                    // (#00896) — fill, radius, font, contents — and only swaps
                    // the slot buttons for the pane's own controls.
                    OmniboxPill(
                        state: state, tabID: id, isSecondaryPane: true,
                        isFloating: state.display.barLayout.position.isFloating
                            || state.display.layout.barFloats)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            paneContent(id, isFocused: isFocused)
        }
        .animation(.easeInOut(duration: ZenTokens.hiddenToolbarTransition), value: showsOwnBar)
    }

    /// The secondary bar follows the main one in compact mode, and is always
    /// present otherwise. It has no collapsed form of its own — a pane bar is
    /// already the short version — so it rides on `expanded` alone.
    private var secondaryBarHidden: Bool {
        state.display.compactModeEnabled && state.settings.compactHidesToolbar
            && state.compactBarPhase != .expanded
    }

    @ViewBuilder
    private func paneContent(_ id: UUID, isFocused: Bool) -> some View {
        pane(id)
            .clipShape(
                RoundedRectangle(cornerRadius: ZenMetrics.contentRadius, style: .continuous)
            )
            .overlay {
                // `outline: 2px solid var(--zen-active-split-outline-color)` —
                // the accent darkened 20% lightness in light mode.
                RoundedRectangle(cornerRadius: ZenMetrics.contentRadius, style: .continuous)
                    .strokeBorder(
                        isFocused ? activeOutlineColor : .clear,
                        lineWidth: ZenMetrics.splitActiveOutline)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard id != state.activeTabID else { return }
                Haptics.shared.fire(.tabSelect)
                state.select(id)
            }
    }

    private var activeOutlineColor: Color {
        guard !palette.isDark else { return palette.primary.color }
        let (hue, saturation, lightness) = palette.accent.hsl
        return ZenColor(
            hueDegrees: hue, saturation: saturation, lightness: max(0, lightness - 20)
        ).color
    }

    /// Upstream's splitter is a bare hit strip in the gap with no fill. A
    /// finger needs a visible, larger target, so we draw a grab pill.
    private func divider(horizontal: Bool, total: CGFloat, fraction: Double) -> some View {
        let offset = total * fraction - total / 2
        return Capsule()
            .fill(palette.text.withAlpha(0.35).color)
            .frame(
                width: horizontal ? ZenMetrics.splitDividerVisualWidth : 40,
                height: horizontal ? 40 : ZenMetrics.splitDividerVisualWidth
            )
            .frame(
                width: horizontal ? ZenMetrics.splitDividerHitWidth : nil,
                height: horizontal ? nil : ZenMetrics.splitDividerHitWidth
            )
            .contentShape(Rectangle())
            .offset(x: horizontal ? offset : 0, y: horizontal ? 0 : offset)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($dragDelta) { value, delta, _ in
                        Haptics.shared.prepare(.dividerSnap)
                        delta = horizontal ? value.translation.width : value.translation.height
                    }
                    .onEnded { value in
                        let moved = horizontal ? value.translation.width : value.translation.height
                        let settled = clampedFraction(dragDelta: moved, total: total)
                        // Tick only where the clamp actually caught it — the
                        // 7% minimum is invisible until you hit it.
                        if settled != state.splitFraction + Double(moved / max(total, 1)) {
                            Haptics.shared.fire(.dividerSnap)
                        }
                        state.splitFraction = settled
                    }
            )
            .accessibilityLabel("Resize split")
    }
}
