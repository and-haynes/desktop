//  OmniboxPill.swift
//  The collapsed urlbar. On iPhone it floats at the *bottom* of the screen so
//  it is thumb-reachable — upstream's inline urlbar sits at the top, but a
//  phone is not a laptop. Tapping it opens the centered floating box.
//
//  Visual reference: `.urlbar:not([breakout-extend])` — 48px tall, the
//  translucent `--zen-toolbar-element-bg` surface, `--border-radius-medium`.

import SwiftUI

struct OmniboxPill: View {
    @ObservedObject var state: BrowserState
    /// Which tab this bar represents. nil means "whatever is active", which is
    /// the ordinary single-pane case; split view gives each pane its own bar
    /// bound to that pane's tab.
    var tabID: UUID?
    /// A secondary pane's bar is slimmer and drops the controls that belong to
    /// the window rather than the pane.
    var isSecondaryPane: Bool = false
    @Environment(\.zenPalette) private var palette
    let onShare: () -> Void

    private var tab: Tab? {
        if let tabID { return state.tab(id: tabID) }
        return state.activeTab
    }

    /// Which pane the user is actually working in.
    private var isActivePane: Bool {
        tabID == nil || tabID == state.activeTabID
    }

    var body: some View {
        HStack(spacing: 6) {
            if isSecondaryPane {
                // The pane indicator doubles as the focus affordance: filled
                // when this is the pane you are in, hollow when it is not.
                Image(systemName: isActivePane ? "circle.fill" : "circle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(
                        isActivePane ? palette.accent.color : palette.text.withAlpha(0.3).color)
                    .frame(width: 22, height: 36)
                    .accessibilityLabel(isActivePane ? "Active pane" : "Inactive pane")
            } else {
                sidebarButton
            }

            Button {
                // Selecting first makes the tapped pane the active one, so the
                // suggestions and the commit both land where you looked.
                if let tabID, tabID != state.activeTabID { state.select(tabID) }
                state.openOmnibox(
                    for: tabID, prefill: tab.map(Self.editableText) ?? "")
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: lockSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.text.withAlpha(0.45).color)
                    Text(displayText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.text.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(ZenPressStyle(pressedScale: 0.99))
            .accessibilityLabel("Address and search")

            if isSecondaryPane {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                        state.splitSecondaryTabID = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.text.withAlpha(0.7).color)
                        .frame(width: 28, height: 36)
                }
                .buttonStyle(ZenPressStyle())
                .accessibilityLabel("Close split pane")
            } else {
                if let tab, !tab.isNewTabPage {
                    bookmarkButton(tab)
                }
                menuButton
            }
        }
        .padding(.horizontal, 6)
        .frame(height: isSecondaryPane ? ZenMetrics.paneBarHeight : ZenMetrics.omniboxPillHeight)
        .zenSurface(palette, radius: ZenMetrics.rowRadius, elevated: true)
        .opacity(isActivePane ? 1 : 0.82)
    }

    // MARK: Pieces

    private var displayText: String {
        guard let tab else { return "Search or enter address" }
        if tab.isNewTabPage { return "Search or enter address" }
        let host = URLDetector.prettyHost(tab.url)
        return host.isEmpty ? tab.url.absoluteString : host
    }

    private var lockSymbol: String {
        guard let tab, !tab.isNewTabPage else { return "magnifyingglass" }
        return tab.url.scheme == "https" ? "lock.fill" : "exclamationmark.triangle.fill"
    }

    /// Editing shows the whole URL, not the pretty host.
    static func editableText(_ tab: Tab) -> String {
        tab.isNewTabPage ? "" : tab.url.absoluteString
    }

    private var sidebarButton: some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                state.isSidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.text.withAlpha(0.7).color)
                .frame(width: 34, height: 36)
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityLabel("Toggle sidebar")
    }

    private func bookmarkButton(_ tab: Tab) -> some View {
        let saved = state.bookmarks.isBookmarked(tab.url)
        return Button {
            state.bookmarks.toggle(
                url: tab.url, title: tab.displayTitle, spaceID: state.activeSpaceID)
        } label: {
            Image(systemName: saved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(saved ? palette.accent.color : palette.text.withAlpha(0.6).color)
                .frame(width: 30, height: 36)
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityLabel(saved ? "Remove bookmark" : "Add bookmark")
    }

    private var menuButton: some View {
        Menu {
            Button {
                NotificationCenter.default.post(name: .zenReloadActiveTab, object: nil)
            } label: { Label("Reload", systemImage: "arrow.clockwise") }

            Button { onShare() } label: { Label("Share", systemImage: "square.and.arrow.up") }

            Button {
                state.isFindBarVisible = true
            } label: { Label("Find in Page", systemImage: "text.magnifyingglass") }

            Toggle(isOn: $state.settings.preferDesktopSite) {
                Label("Request Desktop Site", systemImage: "desktopcomputer")
            }

            Divider()

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 1)) { state.toggleSplit() }
            } label: {
                Label(
                    state.isSplitActive ? "Exit Split View" : "Split View",
                    systemImage: "rectangle.split.2x1")
            }

            Button {
                state.settings.compactModeEnabled.toggle()
            } label: {
                Label(
                    state.settings.compactModeEnabled ? "Exit Compact Mode" : "Compact Mode",
                    systemImage: "rectangle.compress.vertical")
            }

            Divider()

            Button { state.isHistorySheetPresented = true } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            Button { state.isSettingsPresented = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.text.withAlpha(0.7).color)
                .frame(width: 32, height: 36)
                .contentShape(Rectangle())
        }
        // A SwiftUI Menu does not inherit the accessibility label of its own
        // label view, so both are set here explicitly.
        .accessibilityLabel("More")
        .accessibilityIdentifier("moreMenu")
    }
}

extension Notification.Name {
    /// Posted by the overflow menu and the "Reload Tab" omnibox action; RootView
    /// observes it, because only it can reach the web view pool.
    static let zenReloadActiveTab = Notification.Name("zen.reloadActiveTab")
    /// Put a revealed compact toolbar away again — posted when the page is
    /// scrolled. RootView owns the animation.
    static let zenHideRevealedChrome = Notification.Name("zen.hideRevealedChrome")
    /// The page started scrolling. In compact mode this brings the bar back —
    /// reaching for the grabber mid-scroll is exactly when you least want to.
    static let zenPageScrollBegan = Notification.Name("zen.pageScrollBegan")
    /// Scrolling settled. Starts the hide countdown.
    static let zenPageScrollEnded = Notification.Name("zen.pageScrollEnded")
}
