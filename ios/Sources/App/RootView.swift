//  RootView.swift
//  The browser window: gradient background, sidebar, content, omnibox, and the
//  overlays (glance, find bar).
//
//  Layout follows the device. On iPhone the sidebar is a slide-in drawer opened
//  by an edge swipe or the toolbar button, and the urlbar floats at the bottom
//  where a thumb can reach it. On iPad the sidebar is persistent beside the
//  content, as it is on desktop.

import SwiftUI

struct RootView: View {
    @StateObject private var state: BrowserState
    @StateObject private var pool = PoolBox()
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var shareItem: URL?

    @MainActor
    init(state: BrowserState? = nil) {
        // Built lazily inside the autoclosure so restoring the session
        // happens when the scene appears, not while the view tree is built.
        let restored = state
        _state = StateObject(wrappedValue: restored ?? BrowserState())
    }

    /// WebViewPool is not observable by design, so it is parked in a tiny
    /// ObservableObject box to get StateObject's lifetime guarantees.
    @MainActor
    final class PoolBox: ObservableObject {
        let pool = WebViewPool()
    }

    private var palette: ZenPalette { state.palette(systemDark: systemScheme == .dark) }
    private var isPad: Bool { sizeClass == .regular }

    /// Compact mode hides the chrome until an edge gesture reveals it.
    private var chromeHidden: Bool {
        state.settings.compactModeEnabled && !state.compactRevealed
    }
    private var sidebarHidden: Bool {
        chromeHidden && state.settings.compactHidesSidebar
    }
    private var toolbarHidden: Bool {
        chromeHidden && state.settings.compactHidesToolbar
    }

    var body: some View {
        ZStack {
            background
            layout
            compactGrabber
            overlays
        }
        .environment(\.zenPalette, palette)
        // A themed space can override the system scheme (`shouldBeDarkMode`).
        .preferredColorScheme(state.activeSpace?.theme.forcedDarkMode.map { $0 ? .dark : .light })
        .onAppear {
            pool.pool.state = state
            // A restored session has icons for nothing it has not yet loaded;
            // fetch them so the sidebar is not a column of monograms.
            Task { await FaviconService.prefetchMissing(for: state) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenReloadActiveTab)) { _ in
            guard let tabID = state.activeTabID else { return }
            // An unloaded tab has no view to reload; selecting it rebuilds one.
            if let view = pool.pool.existing(for: tabID) {
                view.reload()
            } else {
                state.select(tabID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenHideRevealedChrome)) { _ in
            hideChrome()
        }
        .onChange(of: scenePhase) { _, phase in
            // Flush the session on the way out; a jetsam gives no warning.
            if phase != .active { state.saveNow() }
        }
        .sheet(isPresented: $state.isHistorySheetPresented) {
            HistorySheet(state: state, history: state.history, bookmarks: state.bookmarks)
                .environment(\.zenPalette, palette)
        }
        .sheet(isPresented: $state.isSettingsPresented) {
            SettingsSheet(state: state).environment(\.zenPalette, palette)
        }
        .sheet(item: $shareItem) { url in
            ShareSheet(items: [url])
        }
        .background { keyboardShortcuts }
    }

    // MARK: Background

    private var background: some View {
        ZStack {
            if let space = state.activeSpace {
                ZenGradientView(theme: space.theme, isDark: palette.isDark)
                    .id(space.id)
                    .transition(.opacity)
            } else {
                palette.mainBrowserBackground.color.ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: state.activeSpaceID)
    }

    // MARK: Layout

    @ViewBuilder
    private var layout: some View {
        if isPad {
            padLayout
        } else {
            phoneLayout
        }
    }

    private var padLayout: some View {
        HStack(spacing: 0) {
            if showPadSidebar {
                SidebarView(state: state)
                    .frame(width: ZenMetrics.sidebarWidthPad)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            content
        }
        .animation(
            .spring(response: ZenMetrics.compactAnimationDuration * 2, dampingFraction: 1),
            value: showPadSidebar)
    }

    private var showPadSidebar: Bool {
        guard state.settings.sidebarPinnedOnPad else { return state.isSidebarVisible }
        return !sidebarHidden
    }

    private var phoneLayout: some View {
        ZStack(alignment: .leading) {
            content
            if state.isSidebarVisible {
                // Tap-to-dismiss scrim behind the drawer.
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            state.isSidebarVisible = false
                        }
                    }
                SidebarView(state: state)
                    .frame(width: ZenMetrics.sidebarWidthPhone)
                    .background {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay(palette.themedToolbarBG.withAlpha(0.22).color)
                            .ignoresSafeArea()
                    }
                    .zenBigShadow()
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: state.isSidebarVisible)
        // Edge swipe to open the drawer, as the toolbar button does.
        .gesture(drawerEdgeSwipe)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let space = state.activeSpace {
                ContentArea(state: state, space: space, pool: pool.pool)
                    .padding(.horizontal, ZenMetrics.splitGap)
                    .padding(.top, ZenMetrics.splitGap)
                    // Tapping the page puts a revealed compact toolbar away
                    // again. Simultaneous so it never swallows a page tap.
                    .simultaneousGesture(
                        TapGesture().onEnded { hideChrome() },
                        including: state.compactRevealed ? .all : .subviews)
            }

            VStack(spacing: 8) {
                if state.isFindBarVisible {
                    FindBar(state: state, pool: pool.pool)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !toolbarHidden {
                    OmniboxPill(state: state) { shareItem = state.activeTab?.url }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .animation(.easeInOut(duration: ZenTokens.hiddenToolbarTransition), value: toolbarHidden)
            .animation(.easeInOut(duration: 0.2), value: state.isFindBarVisible)
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private var overlays: some View {
        if let glanceID = state.glanceTabID, let tab = state.tab(id: glanceID),
            let space = state.activeSpace
        {
            GlanceView(tab: tab, space: space, state: state, pool: pool.pool)
                .environment(\.zenPalette, palette)
                .transition(.opacity)
                .zIndex(2)
        }

        if state.isOmniboxOpen {
            OmniboxOverlay(state: state)
                .environment(\.zenPalette, palette)
                .zIndex(3)
        }
    }

    // MARK: Compact-mode grabber

    /// Upstream reveals the hidden chrome when the pointer comes within 10px of
    /// a screen edge. The touch translation of that — a tap strip along the
    /// bottom — sits exactly where the iOS home gesture lives and loses every
    /// race with it. So the reveal is an explicit target instead: a drag-handle
    /// pill just above the home indicator, tapped or pulled up.
    @ViewBuilder
    private var compactGrabber: some View {
        if chromeHidden {
            VStack {
                Spacer()
                Capsule()
                    .fill(palette.text.withAlpha(0.35).color)
                    .frame(
                        width: ZenMetrics.compactGrabberWidth,
                        height: ZenMetrics.compactGrabberHeight)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    // A 6pt pill is not a touch target; 44pt is.
                    .frame(height: ZenMetrics.compactGrabberHitHeight)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { revealChrome() }
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onEnded { value in
                                // Pull up to reveal; a downward flick is the
                                // user reaching for the home gesture.
                                if value.translation.height < -8 { revealChrome() }
                            }
                    )
                    .accessibilityLabel("Show toolbar")
                    .accessibilityAddTraits(.isButton)
            }
            .transition(.opacity)
            .zIndex(1)
        }
    }

    private func revealChrome() {
        withAnimation(
            .spring(response: ZenMetrics.compactAnimationDuration * 2, dampingFraction: 1)
        ) {
            state.compactRevealed = true
        }
    }

    /// The reveal is momentary: tapping the page or scrolling puts it back.
    /// There is no auto-hide timer — a deliberate reveal should not time out.
    private func hideChrome() {
        guard state.compactRevealed else { return }
        withAnimation(.easeInOut(duration: ZenTokens.hiddenToolbarTransition)) {
            state.compactRevealed = false
        }
    }

    private var drawerEdgeSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.startLocation.x < 24 && value.translation.width > 40 {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        state.isSidebarVisible = true
                    }
                } else if state.isSidebarVisible && value.translation.width < -40 {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        state.isSidebarVisible = false
                    }
                }
            }
    }

    // MARK: Hardware keyboard (iPad)

    /// Invisible buttons carrying `.keyboardShortcut`. SwiftUI has no way to
    /// declare a shortcut without a control, so they live in the background
    /// with zero size.
    private var keyboardShortcuts: some View {
        ZStack {
            shortcutButton("t", modifiers: .command) {
                state.newTab()
                state.isOmniboxOpen = true
            }
            shortcutButton("w", modifiers: .command) {
                if let tabID = state.activeTabID { state.closeTab(tabID) }
            }
            shortcutButton("l", modifiers: .command) {
                state.omniboxText = state.activeTab.map(OmniboxPill.editableText) ?? ""
                state.isOmniboxOpen = true
            }
            shortcutButton("f", modifiers: .command) { state.isFindBarVisible = true }
            shortcutButton("s", modifiers: [.command, .shift]) {
                withAnimation(.spring(response: 0.3, dampingFraction: 1)) { state.toggleSplit() }
            }
            shortcutButton("e", modifiers: [.command, .shift]) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                    state.isSidebarVisible.toggle()
                    if state.settings.sidebarPinnedOnPad && isPad {
                        state.settings.sidebarPinnedOnPad = false
                    }
                }
            }
            shortcutButton(.tab, modifiers: .control) { state.cycleTab(by: 1) }
            shortcutButton(.tab, modifiers: [.control, .shift]) { state.cycleTab(by: -1) }
            shortcutButton(.rightArrow, modifiers: [.control, .shift]) {
                withAnimation { state.cycleSpace(by: 1) }
            }
            shortcutButton(.leftArrow, modifiers: [.control, .shift]) {
                withAnimation { state.cycleSpace(by: -1) }
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func shortcutButton(
        _ key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void
    ) -> some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
    }
}

/// UIActivityViewController, for the share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// `sheet(item:)` needs Identifiable; a URL is a perfectly good identity.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
