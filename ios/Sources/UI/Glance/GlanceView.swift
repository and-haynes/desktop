//  GlanceView.swift
//  Zen's Glance: a link opened as a card floating over the page you were on,
//  which you can then expand into a real tab or dismiss.
//
//  Upstream the card is 80% wide and full height, the page behind it scales to
//  0.97 and dims to 0.3, and three round buttons (close / expand / split) sit
//  just outside the card's edge. On a phone a full-height card reads as a wall
//  of page, so we take 88% × 78% and centre it, put the controls in a bar
//  above the card, and add drag-to-dismiss — which upstream has no need for
//  because it has a cursor.

import SwiftUI

struct GlanceView: View {
    let tab: Tab
    let space: Space
    @ObservedObject var state: BrowserState
    let pool: WebViewPool
    @Environment(\.zenPalette) private var palette

    @State private var appeared = false
    @GestureState private var dragY: CGFloat = 0

    /// How far you have to pull down before the card dismisses.
    private let dismissDistance: CGFloat = 130

    var body: some View {
        GeometryReader { geo in
            ZStack {
                scrim
                card(size: geo.size)
                    .offset(y: dragY + (appeared ? 0 : 24))
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.94)
            }
        }
        .onAppear {
            Haptics.shared.fire(.glanceOpen)
            // Spring with `bounce: 0`, as ZenGlanceManager uses.
            withAnimation(.spring(response: ZenMetrics.glanceAnimationDuration, dampingFraction: 1))
            {
                appeared = true
            }
        }
    }

    private var scrim: some View {
        // `opacity: 1 → 0.3` on the parent, expressed as a scrim over it.
        Color.black
            .opacity(appeared ? 1 - ZenMetrics.glanceParentOpacity : 0)
            .ignoresSafeArea()
            .onTapGesture { close() }
    }

    private func card(size: CGSize) -> some View {
        VStack(spacing: 12) {
            controls
            VStack(spacing: 0) {
                header
                WebView(tab: tab, space: space, state: state, pool: pool)
            }
            .frame(
                width: size.width * ZenMetrics.glanceWidthFraction,
                height: size.height * ZenMetrics.glanceHeightFraction)
            .background(palette.mainBrowserBackground.color)
            .clipShape(
                RoundedRectangle(cornerRadius: ZenMetrics.contentRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ZenMetrics.contentRadius, style: .continuous)
                    .strokeBorder(palette.borderContrast.color, lineWidth: 0.5)
            }
            .zenBigShadow()
            .gesture(dragToDismiss)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A grab bar and the page's identity, so you know what you are glancing at.
    private var header: some View {
        HStack(spacing: 8) {
            FaviconView(tab: tab, size: 14)
            Text(tab.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.text.color)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(URLDetector.prettyHost(tab.url))
                .font(.system(size: 11))
                .foregroundStyle(palette.text.withAlpha(0.45).color)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(palette.themedToolbarBG.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border.color).frame(height: 0.5)
        }
    }

    /// The three round buttons from `zen-glance-sidebar-container`.
    private var controls: some View {
        HStack(spacing: 12) {
            ZenCircleButton(symbol: "xmark") { close() }
                .accessibilityLabel("Close Glance")
            ZenCircleButton(symbol: "arrow.up.left.and.arrow.down.right") { expand() }
                .accessibilityLabel("Expand to tab")
            ZenCircleButton(symbol: "rectangle.split.2x1") { splitOut() }
                .accessibilityLabel("Open in split view")
        }
        .environment(\.zenPalette, palette)
    }

    // MARK: Gestures & actions

    private var dragToDismiss: some Gesture {
        DragGesture(minimumDistance: 16)
            .updating($dragY) { value, offset, _ in
                Haptics.shared.prepare(.glanceClose)
                // Downward only, with resistance, so the card cannot be flung
                // off the top of the screen.
                offset = value.translation.height > 0
                    ? value.translation.height
                    : value.translation.height * 0.2
            }
            .onEnded { value in
                if value.translation.height > dismissDistance { close() }
            }
    }

    private func close() {
        Haptics.shared.fire(.glanceClose)
        withAnimation(.easeOut(duration: ZenMetrics.glanceAnimationDuration * 0.7)) {
            appeared = false
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ZenMetrics.glanceAnimationDuration * 0.7
        ) {
            state.closeGlance()
        }
    }

    /// `fullyOpenGlance()` — the card graduates into a first-class tab.
    private func expand() {
        Haptics.shared.fire(.glanceExpand)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            state.expandGlance()
        }
    }

    /// `splitGlance()` — expand, then split against the tab it came from.
    private func splitOut() {
        let glanceID = tab.id
        let parentID = state.activeTabID
        state.expandGlance()
        guard let parentID, parentID != glanceID else { return }
        Haptics.shared.fire(.splitEnter)
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
            state.select(parentID)
            state.split(with: glanceID)
        }
    }
}
