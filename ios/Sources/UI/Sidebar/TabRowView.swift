//  TabRowView.swift
//  One row in the vertical tab sidebar.
//
//  Visual reference: `.tabbrowser-tab` in zen-tabs/vertical-tabs.css — 14px
//  corner radius, 8px inline padding, 8.5px icon gap, 2px block margin, and a
//  close button that only appears on hover. There is no hover on a phone, so
//  the close affordance is a swipe instead and the button is always drawn for
//  the selected row (where upstream also shows it).

import SwiftUI

struct TabRowView: View {
    let tab: Tab
    let isActive: Bool
    @ObservedObject var state: BrowserState
    @Environment(\.zenPalette) private var palette

    /// Swipe-to-close offset.
    @GestureState private var dragOffset: CGFloat = 0
    @State private var isClosing = false
    /// Latches so the threshold tap fires once per crossing, not once a frame.
    @State private var hasCrossedThreshold = false

    /// How far you have to pull before the row commits to closing.
    private let closeThreshold: CGFloat = 96

    var body: some View {
        ZStack(alignment: .trailing) {
            closeBackdrop
            row
                .offset(x: dragOffset)
                .gesture(swipeToClose)
        }
        .frame(height: ZenMetrics.rowHeight)
        .onAppear { Haptics.shared.prepare([.tabSelect, .swipeCloseThreshold]) }
        // `.contextMenu` brings its own system tap on commit, and adding a
        // competing long-press gesture here stole the menu outright. The
        // `longPressMenu` event is used where we own the gesture — the link
        // menu in the page.
        .contextMenu { TabContextMenu(tab: tab, state: state) }
    }

    // MARK: Row content

    private var row: some View {
        Button {
            Haptics.shared.fire(.tabSelect)
            state.select(tab.id)
            if UIDevice.current.userInterfaceIdiom == .phone { state.isSidebarVisible = false }
        } label: {
            HStack(spacing: ZenMetrics.rowIconGap) {
                FaviconView(tab: tab)
                Text(tab.displayTitle)
                    .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? palette.text.color : palette.text.withAlpha(0.78).color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if isActive { closeButton }
            }
            .padding(.horizontal, ZenMetrics.rowInlinePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: ZenMetrics.rowRadius, style: .continuous)
                    .fill(background)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ZenPressStyle(pressedScale: ZenTokens.activeTabScale))
    }

    /// `--tab-background-color-selected: light-dark(rgba(255,255,255,.85), rgba(255,255,255,.2))`
    private var background: Color {
        guard isActive else { return .clear }
        return palette.isDark
            ? Color.white.opacity(0.20)
            : Color.white.opacity(0.85)
    }

    /// Pinned and essential tabs get a reset button rather than a close button —
    /// upstream's `.tab-reset-pin-button`, which restores the pinned URL.
    private var closeButton: some View {
        Button {
            // A pinned tab is restored, not destroyed; that is a success, and
            // it should not feel like a deletion.
            Haptics.shared.fire(tab.kind.resetsOnClose ? .tabRestore : .tabClose)
            withAnimation(.easeOut(duration: 0.18)) { _ = state.closeTab(tab.id) }
        } label: {
            Image(systemName: tab.kind.resetsOnClose ? "arrow.counterclockwise" : "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.text.withAlpha(0.7).color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(palette.toolbarElementHoverBG.color))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.kind.resetsOnClose ? "Reset tab" : "Close tab")
    }

    // MARK: Swipe to close

    private var closeBackdrop: some View {
        RoundedRectangle(cornerRadius: ZenMetrics.rowRadius, style: .continuous)
            .fill(Color(red: 0.86, green: 0.21, blue: 0.27))
            .overlay(alignment: .trailing) {
                Image(systemName: tab.kind.resetsOnClose ? "arrow.counterclockwise" : "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.trailing, 16)
            }
            .opacity(dragOffset < -8 ? 1 : 0)
    }

    private var swipeToClose: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .local)
            .updating($dragOffset) { value, offset, _ in
                // Left only, and with resistance past the threshold so the row
                // never flies off under a careless flick.
                guard value.translation.width < 0 else { return }
                let raw = value.translation.width
                offset = raw < -closeThreshold
                    ? -closeThreshold + (raw + closeThreshold) * 0.25
                    : raw
            }
            .onChanged { value in
                Haptics.shared.prepare(.swipeCloseThreshold)
                // The tap at the threshold is the whole point of the gesture:
                // it tells you the row will go if you let go now, which is
                // otherwise only visible under your own thumb.
                let crossed = value.translation.width <= -closeThreshold
                guard crossed != hasCrossedThreshold else { return }
                hasCrossedThreshold = crossed
                if crossed { Haptics.shared.fire(.swipeCloseThreshold) }
            }
            .onEnded { value in
                hasCrossedThreshold = false
                guard value.translation.width <= -closeThreshold, !isClosing else { return }
                isClosing = true
                Haptics.shared.fire(tab.kind.resetsOnClose ? .tabRestore : .tabClose)
                withAnimation(.easeOut(duration: 0.2)) { _ = state.closeTab(tab.id) }
            }
    }
}

/// Shared by tab rows and essential tiles.
struct TabContextMenu: View {
    let tab: Tab
    @ObservedObject var state: BrowserState

    var body: some View {
        Button {
            Haptics.shared.fire(.pinToggle)
            state.toggleEssential(tab.id)
        } label: {
            Label(
                tab.kind == .essential ? "Remove from Essentials" : "Add to Essentials",
                systemImage: tab.kind == .essential ? "star.slash" : "star")
        }
        .disabled(tab.kind != .essential && state.essentials.count >= ZenMetrics.maxEssentials)

        Button {
            Haptics.shared.fire(.pinToggle)
            state.togglePinned(tab.id)
        } label: {
            Label(tab.kind == .pinned ? "Unpin Tab" : "Pin Tab", systemImage: "pin")
        }

        Button {
            Haptics.shared.fire(.splitEnter)
            state.split(with: tab.id)
        } label: {
            Label("Open in Split View", systemImage: "rectangle.split.2x1")
        }

        Button {
            Haptics.shared.fire(.glanceOpen)
            state.openGlance(url: tab.url)
        } label: {
            Label("Open in Glance", systemImage: "rectangle.on.rectangle.angled")
        }

        Button {
            UIPasteboard.general.url = tab.url
        } label: {
            Label("Copy Link", systemImage: "doc.on.doc")
        }

        Divider()

        // Essentials are never destructively closed upstream; they can only be
        // removed from Essentials first.
        if tab.kind != .essential {
            Button(role: .destructive) {
                Haptics.shared.fire(tab.kind.resetsOnClose ? .tabRestore : .tabClose)
                state.closeTab(tab.id)
            } label: {
                Label(
                    tab.kind == .pinned ? "Reset Pinned Tab" : "Close Tab",
                    systemImage: tab.kind == .pinned ? "arrow.counterclockwise" : "xmark")
            }
        }
    }
}
