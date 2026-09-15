//  OmniboxPill.swift
//  The collapsed urlbar. On iPhone it floats at the *bottom* of the screen so
//  it is thumb-reachable — upstream's inline urlbar sits at the top, but a
//  phone is not a laptop. Tapping it opens the centered floating box.
//
//  Visual reference: `.urlbar:not([breakout-extend])` — 48px tall, the
//  translucent `--zen-toolbar-element-bg` surface, `--border-radius-medium`.
//
//  Since #00896 none of those numbers are constants any more: the bar draws
//  itself from a `BarLayout`, which is what the "Customize bar" editor writes
//  and what the editor's live preview reads. Everything here that used to be a
//  literal is now a lookup, and the buttons are a list rather than a hard-wired
//  row — so this file is the *renderer* for a layout, not a design of its own.

import SwiftUI

struct OmniboxPill: View {
    @ObservedObject var state: BrowserState
    /// Which tab this bar represents. nil means "whatever is active", which is
    /// the ordinary single-pane case; split view gives each pane its own bar
    /// bound to that pane's tab.
    var tabID: UUID?
    /// A secondary pane's bar is slimmer and swaps the slot buttons for the
    /// pane controls — it still follows the layout for everything else.
    var isSecondaryPane: Bool = false
    /// Full-screen layout, or a floating bar position, puts the bar over the
    /// page rather than in the flow.
    var isFloating: Bool = false
    /// The editor's live preview passes the layout being edited rather than the
    /// saved one, so every change shows before it is committed.
    var layoutOverride: BarLayout?
    /// A preview is drawn, not wired up: no navigation, no haptics, no menus
    /// that could be opened over the editor that is drawing them.
    var isPreview: Bool = false
    @Environment(\.zenPalette) private var palette
    var onShare: (URL) -> Void = { _ in }
    /// Put the bar away. Owned by whoever animates it (RootView).
    var onHideBar: () -> Void = {}

    var layout: BarLayout { layoutOverride ?? state.settings.barLayout }

    /// Double-tap bookkeeping for the address area — see `addressTapped()`.
    @State private var lastAddressTap = Date.distantPast
    @State private var pendingAddressTap: Task<Void, Never>?
    /// When the bar's own swipe last passed its minimum distance.
    ///
    /// `simultaneousGesture` *composes* rather than arbitrates: the swipe and
    /// the address button both recognise the same touch, so swiping down to
    /// hide the bar also opened the omnibox over the top of it. The swipe sets
    /// this the moment it passes 12pt — which is the definition of "this was
    /// not a tap" — and the button checks it.
    @State private var lastBarDrag = Date.distantPast

    private var tab: Tab? {
        if let tabID { return state.tab(id: tabID) }
        return state.activeTab
    }

    /// Which pane the user is actually working in.
    private var isActivePane: Bool {
        tabID == nil || tabID == state.activeTabID
    }

    private var navigation: TabNavigationState { state.navigation(for: tab?.id) }

    /// The glyph colour. `fixed` keeps one colour whatever space you are in,
    /// which is the point of the option — a bar that does not change under you.
    private var accent: ZenColor {
        guard layout.accentSource == .fixed, let fixed = layout.fixedAccent else {
            return palette.accent
        }
        return fixed
    }

    private var barHeight: CGFloat {
        isSecondaryPane
            ? min(CGFloat(layout.height), ZenMetrics.paneBarHeight + 4)
            : CGFloat(layout.height)
    }

    private var fill: BarFill { layout.resolvedFill(default: state.settings.barFill) }

    private var context: BarActionContext {
        BarActionContext(
            tabID: tabID, share: onShare, hideBar: onHideBar,
            showActionMenu: {})
    }

    var body: some View {
        HStack(spacing: 6) {
            leadingControls
            addressArea
            trailingControls
        }
        .padding(.horizontal, 6)
        .frame(height: barHeight)
        .background { progressFill }
        .overlay(alignment: .bottom) { progressLine }
        .zenBarChrome(
            layout: layout, fill: fill, palette: palette, isInteractive: !isPreview,
            height: barHeight
        )
        .opacity(isActivePane ? 1 : 0.82)
        .modifier(
            BarGestures(
                state: state, layout: layout, context: context, enabled: !isPreview,
                lastDrag: $lastBarDrag, overflow: { AnyView(overflowItems) }))
    }

    // MARK: Slots

    /// Sidebar button placement (#008A8): a slot's side is whatever the user
    /// put it on — the customisable bar already has a general mechanism for
    /// that (drag a `.sidebar` item between `leftSlots`/`rightSlots` in the
    /// Customize bar editor), and `sidebarEdge` does not fight it. The
    /// built-in ios drawer instead force-mirrors a hard-wired button, because
    /// it has no slot system to defer to.
    @ViewBuilder
    private var leadingControls: some View {
        if isSecondaryPane {
            // The pane indicator doubles as the focus affordance: filled when
            // this is the pane you are in, hollow when it is not.
            Image(systemName: isActivePane ? "circle.fill" : "circle")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(
                    isActivePane ? accent.color : palette.text.withAlpha(0.3).color)
                .frame(width: 22, height: 36)
                .accessibilityLabel(isActivePane ? "Active pane" : "Inactive pane")
        } else {
            ForEach(layout.leftSlots) { item in
                slotButton(item)
            }
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        if isSecondaryPane {
            Button {
                fire(.splitExit)
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
            .disabled(isPreview)
            .accessibilityLabel("Close split pane")
        } else {
            // Focus's signature control is not a slot: the whole promise of the
            // mode is that Erase is always there, so it cannot be customised
            // away (#00888).
            if state.isFocusMode && !isPreview {
                FocusEraseButton(state: state)
            }
            ForEach(layout.rightSlots) { item in
                slotButton(item)
            }
        }
    }

    @ViewBuilder
    private func slotButton(_ item: BarSlotItem) -> some View {
        switch item.action {
        case .overflowMenu:
            Menu {
                overflowItems
            } label: {
                glyph(for: item.action, enabled: true)
            }
            .disabled(isPreview)
            .accessibilityLabel("More")
            .accessibilityIdentifier("moreMenu")
        case .spaceSwitcher:
            Menu {
                ForEach(state.spaces) { space in
                    Button {
                        withAnimation { state.switchSpace(to: space.id) }
                    } label: {
                        Label {
                            Text(space.name)
                        } icon: {
                            SpaceIconView(space: space, size: 15)
                        }
                    }
                }
            } label: {
                glyph(for: item.action, enabled: true)
            }
            .disabled(isPreview)
            .accessibilityLabel("Spaces")
        default:
            let enabled = BarActionRunner.isEnabled(item.action, state: state, tabID: tabID)
            Button {
                run(item.action)
            } label: {
                glyph(for: item.action, enabled: enabled)
            }
            .buttonStyle(ZenPressStyle())
            .disabled(isPreview || !enabled)
            .accessibilityLabel(item.action.title)
            .accessibilityIdentifier("barSlot-\(item.action.rawValue)")
            .modifier(
                SlotLongPress(action: item.longPress, enabled: !isPreview) { [self] secondary in
                    run(secondary)
                })
        }
    }

    /// One slot glyph. Latching actions (bookmark, split, compact, Focus) are
    /// drawn in the accent when they are on — otherwise you cannot tell a
    /// toggle from a button.
    private func glyph(for action: BarAction, enabled: Bool) -> some View {
        let isOn = BarActionRunner.isOn(action, state: state, tabID: tabID)
        let symbol = action.symbol(
            isLoading: navigation.isLoading,
            isBookmarked: BarActionRunner.isOn(.bookmark, state: state, tabID: tabID))
        return Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(
                isOn ? accent.color : palette.text.withAlpha(enabled ? 0.7 : 0.28).color
            )
            .frame(width: 32, height: 36)
            .contentShape(Rectangle())
    }

    // MARK: The address area

    /// The pill's middle: badge, favicon, the label, and the optional find
    /// affordance. A tap opens the omnibox; a double tap runs whatever the
    /// layout assigned to it.
    @ViewBuilder
    private var addressArea: some View {
        let content = HStack(spacing: 7) {
            if layout.contents.showsSecurityBadge { securityBadge }
            if layout.contents.showsFavicon, let tab {
                FaviconView(tab: tab, size: 15)
            }
            Text(displayText)
                .font(.system(size: CGFloat(layout.urlFontSize), weight: .medium))
                .foregroundStyle(palette.text.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if layout.contents.showsFindButton && !isSecondaryPane {
                Button {
                    run(.findInPage)
                } label: {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.text.withAlpha(0.5).color)
                        .frame(width: 24, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ZenPressStyle())
                .disabled(isPreview)
                .accessibilityLabel("Find in page")
            }
        }
        .padding(.horizontal, layout.contents.showsSecurityBadge ? 4 : 12)
        .frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(Rectangle())

        // Always a Button, even with a double tap assigned.
        //
        // The obvious alternative — `.onTapGesture(count: 2)` then
        // `.onTapGesture` — was wrong in a way only the simulator showed: a
        // *swipe* on the bar fired the single tap as well as the swipe, so
        // "swipe down to hide the bar" hid the bar and opened the omnibox over
        // the top of it. A `Button` cancels its tap the moment the finger
        // travels, which is exactly the arbitration needed here; the second tap
        // is counted by hand below instead.
        //
        // A `Button` already publishes as a single accessibility element, so no
        // `accessibilityElement(children:)` is needed — and adding one stops it
        // publishing as a button at all, which is how the duplicate-element
        // problem got traded for an invisible one.
        Button { addressTapped() } label: { content }
            .buttonStyle(ZenPressStyle(pressedScale: 0.99))
            .disabled(isPreview)
            .accessibilityLabel("Address and search")
            .accessibilityIdentifier("addressBar")
    }

    /// How long a second tap has to arrive to count as a double tap. The same
    /// window a system double tap uses, and the same delay `.onTapGesture(count:
    /// 2)` would have imposed — except that here it only applies when a double
    /// tap is actually assigned, so setting it to Nothing gets the instant
    /// omnibox back.
    private static let doubleTapWindow: TimeInterval = 0.26

    /// How long after a recognised swipe a tap is ignored. Long enough to cover
    /// the touch-up that ends the swipe, short enough that the next deliberate
    /// tap is never eaten.
    private static let swipeSuppression: TimeInterval = 0.4

    private func addressTapped() {
        // The touch that just ended was a swipe; the bar has already acted on
        // it. See `lastBarDrag`.
        guard Date().timeIntervalSince(lastBarDrag) > Self.swipeSuppression else { return }
        guard let doubleTap = layout.gestures[.doubleTap], doubleTap != .none, !isPreview else {
            openOmnibox()
            return
        }
        pendingAddressTap?.cancel()
        if Date().timeIntervalSince(lastAddressTap) < Self.doubleTapWindow {
            lastAddressTap = .distantPast
            run(doubleTap)
            return
        }
        lastAddressTap = Date()
        pendingAddressTap = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.doubleTapWindow))
            guard !Task.isCancelled else { return }
            openOmnibox()
        }
    }

    private func openOmnibox() {
        guard !isPreview else { return }
        fire(.omniboxOpen)
        // Selecting first makes the tapped pane the active one, so the
        // suggestions and the commit both land where you looked.
        if let tabID, tabID != state.activeTabID { state.select(tabID) }
        state.openOmnibox(for: tabID, prefill: tab.map(Self.editableText) ?? "")
    }

    private var displayText: String {
        guard let tab else { return "Search or enter address" }
        if tab.isNewTabPage { return "Search or enter address" }
        switch layout.contents.label {
        case .fullURL:
            return tab.url.absoluteString
        case .pageTitle:
            // Falls back to the host until a title arrives, rather than showing
            // an empty bar for the first second of every load.
            return tab.title.isEmpty ? URLDetector.prettyHost(tab.url) : tab.title
        case .domain:
            let host = URLDetector.prettyHost(tab.url)
            return host.isEmpty ? tab.url.absoluteString : host
        }
    }

    /// The glyph, and — when there is something behind it — the button that
    /// opens it. A warning triangle you cannot tap is the whole of #0089A:
    /// it tells you something is wrong and gives you nowhere to go.
    @ViewBuilder
    private var securityBadge: some View {
        let badge = state.securityBadge(for: tab)
        let glyph = Image(systemName: badge.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(
                badge.isWarning ? ZenTokens.warningColor.color : palette.text.withAlpha(0.45).color)

        if badge.isActionable && !isPreview {
            Button {
                fire(.longPressMenu)
                if let tabID, tabID != state.activeTabID { state.select(tabID) }
                state.openSecurityDetail(for: tab)
            } label: {
                glyph
                    .frame(width: 26, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ZenPressStyle())
            .accessibilityIdentifier("securityBadge")
            .accessibilityLabel(badge.accessibilityLabel)
        } else {
            glyph
                .frame(width: 20, height: 36)
                .accessibilityLabel(badge.accessibilityLabel)
        }
    }

    /// Editing shows the whole URL, not the pretty host.
    static func editableText(_ tab: Tab) -> String {
        tab.isNewTabPage ? "" : tab.url.absoluteString
    }

    // MARK: Progress

    /// The bar's own surface filling from the left. Costs no extra height,
    /// which on a phone is the argument for it.
    @ViewBuilder
    private var progressFill: some View {
        if layout.contents.progress == .fill, navigation.showsProgress {
            GeometryReader { geo in
                accent.withAlpha(0.22).color
                    .frame(width: geo.size.width * navigation.progress)
                    .animation(.easeOut(duration: 0.2), value: navigation.progress)
            }
        }
    }

    /// A hairline along the bottom edge, as a desktop browser draws it.
    @ViewBuilder
    private var progressLine: some View {
        if layout.contents.progress == .line, navigation.showsProgress {
            GeometryReader { geo in
                accent.color
                    .frame(width: geo.size.width * navigation.progress, height: 2)
                    .animation(.easeOut(duration: 0.2), value: navigation.progress)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: The overflow menu

    /// Built from the layout's overflow slot, so what is in the menu is as
    /// customisable as what is on the bar.
    @ViewBuilder
    private var overflowItems: some View {
        ForEach(layout.overflowSlots) { item in
            Button {
                run(item.action)
            } label: {
                Label(
                    menuTitle(item.action),
                    systemImage: item.action.symbol(
                        isLoading: navigation.isLoading,
                        isBookmarked: BarActionRunner.isOn(
                            .bookmark, state: state, tabID: tabID)))
            }
            .disabled(!BarActionRunner.isEnabled(item.action, state: state, tabID: tabID))
        }
        if layout.overflowSlots.isEmpty {
            Button { state.isSettingsPresented = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    /// A menu row says what it will do, not what the thing is called — the
    /// glyph on the bar has no room for "Exit Split View" but a menu does.
    private func menuTitle(_ action: BarAction) -> String {
        switch action {
        case .reloadStop: return navigation.isLoading ? "Stop" : "Reload"
        case .splitView: return state.isSplitActive ? "Exit Split View" : "Split View"
        case .compactToggle:
            return state.settings.compactModeEnabled ? "Exit Compact Mode" : "Compact Mode"
        case .focusMode: return state.isFocusMode ? "Leave Focus (erases)" : "Focus Mode"
        case .desktopSite:
            return state.settings.preferDesktopSite ? "Request Mobile Site" : "Request Desktop Site"
        case .bookmark:
            return BarActionRunner.isOn(.bookmark, state: state, tabID: tabID)
                ? "Remove Bookmark" : "Add Bookmark"
        case .layoutCycle: return "Layout: \(state.settings.layout.displayName)"
        case .sidebar: return "Tabs"
        case .localServices: return "Local"
        default: return action.title
        }
    }

    // MARK: Plumbing

    private func run(_ action: BarAction) {
        guard !isPreview else { return }
        BarActionRunner.perform(action, state: state, context: context)
    }

    private func fire(_ event: HapticEvent) {
        guard layout.haptics, !isPreview else { return }
        Haptics.shared.fire(event)
    }
}

// MARK: - Long press on a slot button

/// A second action on a held button. Applied as a modifier so a slot with no
/// secondary action carries no gesture at all — an empty `onLongPressGesture`
/// still delays the tap it is attached to.
private struct SlotLongPress: ViewModifier {
    let action: BarAction?
    let enabled: Bool
    let run: (BarAction) -> Void

    func body(content: Content) -> some View {
        if let action, action != .none, enabled {
            content.onLongPressGesture(minimumDuration: 0.45) {
                Haptics.shared.fire(.longPressMenu)
                run(action)
            }
        } else {
            content
        }
    }
}

// MARK: - Gestures on the bar itself

/// Swipes, the long press and the double tap, resolved through the layout's
/// gesture table (#00896). The double tap lives on the address area — see
/// `addressArea` — because it has to be arbitrated against the tap that opens
/// the omnibox; everything else can sit on the whole bar.
private struct BarGestures<Menu: View>: ViewModifier {
    @ObservedObject var state: BrowserState
    let layout: BarLayout
    let context: BarActionContext
    let enabled: Bool
    /// Stamped when the drag passes its minimum distance, so the address
    /// button can tell a swipe from a tap.
    @Binding var lastDrag: Date
    let overflow: () -> Menu

    func body(content: Content) -> some View {
        guard enabled else { return AnyView(content) }
        var view = AnyView(content.simultaneousGesture(swipe))
        switch layout.gestures[.longPress] {
        case .some(.actionMenu):
            // The system's own long-press menu: it is the only thing that can
            // put a menu next to a bar with no anchor of its own.
            view = AnyView(view.contextMenu { overflow() })
        case .some(let action) where action != .none:
            view = AnyView(
                view.onLongPressGesture(minimumDuration: 0.5) {
                    if layout.haptics { Haptics.shared.fire(.longPressMenu) }
                    BarActionRunner.perform(action, state: state, context: context)
                })
        default:
            break
        }
        return view
    }

    /// `simultaneousGesture` with a non-zero minimum distance: the tap that
    /// opens the omnibox and the buttons at either end all keep working, and a
    /// gesture that never travels 12pt is a tap, not a swipe.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { _ in
                // Only reached once the touch has travelled 12pt, which is
                // exactly the "this is not a tap" signal the button needs.
                lastDrag = Date()
                if layout.haptics { Haptics.shared.prepare(.sidebarSnap) }
            }
            .onEnded { value in
                guard
                    let action = BarSwipeGesture.action(
                        translation: value.translation, velocity: value.velocity, layout: layout,
                        sidebarEdge: state.settings.sidebarEdge)
                else { return }
                if layout.haptics { Haptics.shared.fire(.sidebarSnap) }
                BarActionRunner.perform(action, state: state, context: context)
            }
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
    /// Put the page's video into Picture in Picture (#008B0). Posted by the
    /// `popOutVideo` bar action and the page's context menu; RootView observes
    /// it, for the same reason as `zenReloadActiveTab` — the web view lives in
    /// the pool.
    static let zenPopOutVideo = Notification.Name("zen.popOutVideo")
    /// Advance the layout cycle. RootView owns the transition animation.
    static let zenCycleLayout = Notification.Name("zen.cycleLayout")
    /// Every Focus tab has been torn down; the pool must drop their web views
    /// so no content process outlives the erase. `userInfo["tabs"]` is the list
    /// of tab ids as strings.
    static let zenFocusErased = Notification.Name("zen.focusErased")
    /// Enter or leave Focus. RootView owns it, because entering has to compile
    /// the blocklist before any Focus tab is created.
    static let zenToggleFocusMode = Notification.Name("zen.toggleFocusMode")
}
