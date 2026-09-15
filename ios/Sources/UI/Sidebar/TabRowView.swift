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
        .contextMenu { TabContextMenu(tab: tab, state: state) }
    }

    // MARK: Row content

    private var row: some View {
        Button {
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
            .onEnded { value in
                guard value.translation.width <= -closeThreshold, !isClosing else { return }
                isClosing = true
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
            state.toggleEssential(tab.id)
        } label: {
            Label(
                tab.kind == .essential ? "Remove from Essentials" : "Add to Essentials",
                systemImage: tab.kind == .essential ? "star.slash" : "star")
        }
        .disabled(tab.kind != .essential && state.essentials.count >= ZenMetrics.maxEssentials)

        Button {
            state.togglePinned(tab.id)
        } label: {
            Label(tab.kind == .pinned ? "Unpin Tab" : "Pin Tab", systemImage: "pin")
        }

        Button {
            state.split(with: tab.id)
        } label: {
            Label("Open in Split View", systemImage: "rectangle.split.2x1")
        }

        Button {
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
                state.closeTab(tab.id)
            } label: {
                Label(
                    tab.kind == .pinned ? "Reset Pinned Tab" : "Close Tab",
                    systemImage: tab.kind == .pinned ? "arrow.counterclockwise" : "xmark")
            }
        }
    }
}
