//  SidebarView.swift
//  Zen's vertical tab sidebar: essentials grid, this space's pinned tabs, the
//  separator with its clear affordance, then normal tabs — and the space
//  switcher along the bottom.
//
//  ZenSpacesSwipe binds a horizontal trackpad swipe on the tab strip to a
//  space change, with the strip translating live under the finger. We do the
//  same with a drag gesture: the whole list follows the finger, then springs
//  into the next space.

import SwiftUI

struct SidebarView: View {
    @ObservedObject var state: BrowserState
    @Environment(\.zenPalette) private var palette
    @State private var editingSpace: Space?
    @State private var isCreatingSpace = false
    @GestureState private var swipe: CGFloat = 0

    /// `zen.workspaces.swipe-actions.delta-multiplier` — how far you have to
    /// pull before the space actually changes.
    private let swipeCommitDistance: CGFloat = 70

    var body: some View {
        VStack(spacing: 0) {
            if let space = state.activeSpace {
                SpaceIndicator(space: space) { editingSpace = space }
                    .padding(.horizontal, ZenMetrics.sidebarPadding)
            }

            tabList
                // Live swipe feedback, as `_organizeWorkspaceStripLocations`
                // does with translateX.
                .offset(x: swipe)
                .gesture(spaceSwipe)

            newTabStrip

            SpaceSwitcherStrip(
                state: state, editingSpace: $editingSpace, isCreatingSpace: $isCreatingSpace)
        }
        .frame(maxHeight: .infinity)
        .sheet(item: $editingSpace) { space in
            SpaceEditorView(state: state, space: space)
        }
        .sheet(isPresented: $isCreatingSpace) {
            SpaceEditorView(state: state, space: nil)
        }
    }

    // MARK: Sections

    private var tabList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZenMetrics.rowSpacing) {
                EssentialsGrid(state: state)
                    .padding(.bottom, 6)

                ForEach(state.pinnedTabs) { tab in
                    TabRowView(tab: tab, isActive: tab.id == state.activeTabID, state: state)
                }

                separator

                ForEach(state.normalTabs) { tab in
                    TabRowView(tab: tab, isActive: tab.id == state.activeTabID, state: state)
                }
            }
            .padding(.horizontal, ZenMetrics.sidebarPadding)
            .padding(.bottom, 12)
            .animation(.easeInOut(duration: 0.18), value: state.tabs.map(\.id))
        }
        .scrollDismissesKeyboard(.immediately)
    }

    /// `.pinned-tabs-container-separator` — a 22px band holding a 1px rule and
    /// a "clear tabs" button that upstream fades in at 0.5 opacity on hover.
    private var separator: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(palette.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10))
                .frame(height: 1)
                .padding(.horizontal, 4)

            if !state.normalTabs.isEmpty {
                Button {
                    Haptics.shared.fire(.tabClose)
                    withAnimation(.easeInOut(duration: 0.2)) { state.clearNormalTabs() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("Clear")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(palette.text.withAlpha(0.5).color)
                }
                .buttonStyle(ZenPressStyle())
                .accessibilityLabel("Clear tabs")
            }
        }
        .frame(height: ZenMetrics.separatorHeight)
        .opacity(state.pinnedTabs.isEmpty && state.normalTabs.isEmpty ? 0 : 1)
    }

    /// Upstream's new-tab row sits at the end of the tab list and scrolls away
    /// with it. On a phone the control you reach for most should never have to
    /// be found, so it is pinned below the list as a full-width strip at the
    /// 44pt minimum — and it stays put in every layout, because it is outside
    /// the scroll view rather than the last thing in it.
    private var newTabStrip: some View {
        Button {
            Haptics.shared.fire(.tabOpen)
            state.newTab()
            if UIDevice.current.userInterfaceIdiom == .phone { state.isSidebarVisible = false }
            state.isOmniboxOpen = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text("New Tab")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(palette.text.withAlpha(0.8).color)
            .frame(maxWidth: .infinity)
            .frame(height: ZenMetrics.newTabStripHeight)
            .background {
                RoundedRectangle(cornerRadius: ZenMetrics.rowRadius, style: .continuous)
                    .fill(palette.toolbarElementHoverBG.color)
            }
            .overlay {
                RoundedRectangle(cornerRadius: ZenMetrics.rowRadius, style: .continuous)
                    .strokeBorder(palette.border.color, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        // A whole-width target should compress a little less than a tab row, or
        // the press reads as the panel moving rather than the button.
        .buttonStyle(ZenPressStyle(pressedScale: 0.985))
        .accessibilityIdentifier("newTabStrip")
        .padding(.horizontal, ZenMetrics.sidebarPadding)
        .padding(.top, 6)
    }

    // MARK: Space swipe (ZenSpacesSwipe)

    private var spaceSwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .updating($swipe) { value, offset, _ in
                // Only horizontal pulls; a vertical drag belongs to the list.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                Haptics.shared.prepare([.spaceSwitchTick, .spaceSettle])
                let raw = value.translation.width
                // Upstream applies a force multiplier that resists as you near
                // the edge of the travel; same idea, simpler curve.
                offset = raw * 0.5
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height),
                    abs(value.translation.width) > swipeCommitDistance
                else { return }
                // Pulling right reveals the space to the left.
                let delta = value.translation.width < 0 ? 1 : -1
                // Tick as the space changes, then settle once the spring has
                // had time to carry the strip home.
                Haptics.shared.fire(.spaceSwitchTick)
                withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                    state.cycleSpace(by: delta)
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(240))
                    Haptics.shared.fire(.spaceSettle)
                }
            }
    }
}
