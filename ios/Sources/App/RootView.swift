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
    /// Countdown that puts the compact bar away after scrolling stops.
    @State private var compactHideTask: Task<Void, Never>?
    /// The window's top safe-area inset, measured once at the root. With the
    /// status bar hidden the content ignores that inset, so the web view needs
    /// the number explicitly to keep a page's own header out from under the
    /// Dynamic Island.
    @State private var safeAreaTop: CGFloat = 0

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

    /// Generators warmed as the scene becomes active. A cold generator lands
    /// its tap tens of milliseconds late, which reads as a glitch rather than
    /// as feedback; these are the events most likely to be the first one felt.
    private static let warmEvents: [HapticEvent] = [
        .tabSelect, .tabOpen, .tabClose, .swipeCloseThreshold, .omniboxOpen, .urlCommit,
        .sidebarSnap, .spaceSwitchTick,
    ]

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
        GeometryReader { proxy in
            ZStack {
                background
                layout
                compactGrabber
                overlays
            }
            .onAppear { safeAreaTop = proxy.safeAreaInsets.top }
            .onChange(of: proxy.safeAreaInsets.top) { _, top in safeAreaTop = top }
        }
        .environment(\.zenPalette, palette)
        // Applied at the *root* so it holds across every layout, the sheets and
        // the omnibox overlay: the hosting controller owns
        // `prefersStatusBarHidden`, and the sheets we present are page sheets,
        // which do not capture status-bar appearance from their presenter.
        .statusBarHidden(!state.settings.showStatusBar)
        .animation(.easeInOut(duration: 0.25), value: state.settings.showStatusBar)
        // An explicit Light/Dark wins; on Follow System a themed space can
        // still override via `shouldBeDarkMode`.
        .preferredColorScheme(state.preferredColorScheme(systemDark: systemScheme == .dark))
        .onAppear {
            Haptics.shared.prepare(Self.warmEvents)
            pool.pool.state = state
            // A restored session has icons for nothing it has not yet loaded;
            // fetch them so the sidebar is not a column of monograms.
            Task { await FaviconService.prefetchMissing(for: state) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenReloadActiveTab)) { _ in
            guard let tabID = state.activeTabID else { return }
            // An unloaded tab has no view to reload; selecting it rebuilds one.
            if let view = pool.pool.existing(for: tabID) {
                // A failed load has nothing committed, so reload() is a no-op;
                // clearing the guard lets the URL be requested again.
                if state.tab(id: tabID)?.loadFailure != nil {
                    view.lastRequestedURL = nil
                    state.updateTab(tabID) { $0.loadFailure = nil }
                } else {
                    view.reload()
                }
            } else {
                state.select(tabID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenHideRevealedChrome)) { _ in
            hideChrome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenPageScrollBegan)) { _ in
            // Nothing may buzz during a scroll — see `Haptics.isScrolling`.
            Haptics.shared.isScrolling = true
            revealChromeWhileScrolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenPageScrollEnded)) { _ in
            Haptics.shared.isScrolling = false
            scheduleCompactHide()
        }
        .onChange(of: scenePhase) { _, phase in
            // Flush the session on the way out; a jetsam gives no warning.
            if phase != .active { state.saveNow() }
            // A haptic fired from a background task is a phantom buzz in
            // someone's pocket.
            Haptics.shared.isForeground = phase == .active
            if phase == .active { Haptics.shared.prepare(Self.warmEvents) }
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

    /// With the status bar hidden there is nothing left in the top band but
    /// empty gradient, so the page takes it back. `.container` rather than
    /// `.all` keeps the keyboard pushing the layout, and releasing only the
    /// *top* edge leaves the horizontal insets intact — which is exactly where
    /// the Dynamic Island intrudes in landscape.
    private var reclaimsTopEdge: Bool { !state.settings.showStatusBar }

    /// The island is hardware: hiding the status bar does not shrink the top
    /// safe area on a device that has one. So the card runs to the very top
    /// while the *page* is inset by that same amount, and a site's own header
    /// still starts below the pill instead of behind it.
    private var webTopInset: CGFloat { reclaimsTopEdge ? safeAreaTop : 0 }

    private var content: some View {
        VStack(spacing: 0) {
            if let space = state.activeSpace {
                ContentArea(
                    state: state, space: space, pool: pool.pool,
                    topContentInset: webTopInset
                )
                .padding(.horizontal, ZenMetrics.splitGap)
                .padding(.top, reclaimsTopEdge ? 0 : ZenMetrics.splitGap)
                .ignoresSafeArea(.container, edges: reclaimsTopEdge ? .top : [])
                .animation(
                    .easeInOut(duration: 0.25), value: state.settings.showStatusBar
                )
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
                    .fill(palette.text.withAlpha(0.75).color)
                    .frame(
                        width: ZenMetrics.compactGrabberWidth,
                        height: ZenMetrics.compactGrabberHeight)
                    // The page behind can be any colour, and a bare 35%-alpha
                    // pill simply vanished against a light one. A material pad
                    // behind it gives the handle something to sit on, the way
                    // a system sheet grabber does.
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay { Capsule().fill(palette.brandingBG.withAlpha(0.35).color) }
                    }
                    .overlay {
                        Capsule().strokeBorder(palette.borderContrast.color, lineWidth: 0.5)
                    }
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                    // A 6pt pill is not a touch target; 44pt is.
                    .frame(height: ZenMetrics.compactGrabberHitHeight)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { revealChrome() }
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { _ in Haptics.shared.prepare(.grabberDrag) }
                            .onEnded { value in
                                // Pull up to reveal; a downward flick is the
                                // user reaching for the home gesture.
                                if value.translation.height < -8 {
                                    Haptics.shared.fire(.grabberDrag)
                                    revealChrome()
                                }
                            }
                    )
                    .accessibilityLabel("Show toolbar")
                    .accessibilityAddTraits(.isButton)
            }
            .transition(.opacity)
            .zIndex(1)
        }
    }

    /// The grabber's deliberate reveal: no countdown, it stays until the page
    /// is tapped or scrolled.
    private func revealChrome() {
        compactHideTask?.cancel()
        compactHideTask = nil
        Haptics.shared.fire(.compactBarShow)
        withAnimation(
            .spring(response: ZenMetrics.compactAnimationDuration * 2, dampingFraction: 1)
        ) {
            state.compactRevealed = true
        }
    }

    /// Scrolling brings the bar back for as long as you keep scrolling. Each
    /// scroll event restarts the countdown, so a long flick does not flicker.
    private func revealChromeWhileScrolling() {
        guard state.settings.compactModeEnabled else { return }
        compactHideTask?.cancel()
        compactHideTask = nil
        guard !state.compactRevealed else { return }
        withAnimation(.easeOut(duration: ZenTokens.hiddenToolbarTransition)) {
            state.compactRevealed = true
        }
    }

    /// Start the fade-out countdown. Cancelled by any further scrolling, so
    /// the bar only goes when the page has actually settled.
    private func scheduleCompactHide() {
        guard state.settings.compactModeEnabled, state.compactRevealed else { return }
        compactHideTask?.cancel()
        let delay = max(0.2, state.settings.compactHideDelay)
        compactHideTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: ZenTokens.hiddenToolbarTransition)) {
                state.compactRevealed = false
            }
        }
    }

    /// The reveal is momentary: tapping the page or scrolling puts it back.
    /// There is no auto-hide timer — a deliberate reveal should not time out.
    private func hideChrome() {
        compactHideTask?.cancel()
        compactHideTask = nil
        guard state.compactRevealed else { return }
        Haptics.shared.fire(.compactBarHide)
        withAnimation(.easeInOut(duration: ZenTokens.hiddenToolbarTransition)) {
            state.compactRevealed = false
        }
    }

    private var drawerEdgeSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { _ in Haptics.shared.prepare(.sidebarSnap) }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.startLocation.x < 24 && value.translation.width > 40 {
                    Haptics.shared.fire(.sidebarSnap)
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        state.isSidebarVisible = true
                    }
                } else if state.isSidebarVisible && value.translation.width < -40 {
                    Haptics.shared.fire(.sidebarSnap)
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

    /// Every shortcut here changes what is on screen, and a hardware keyboard
    /// gives no other confirmation that the chord was caught.
    private func shortcutButton(
        _ key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void
    ) -> some View {
        Button("") {
            Haptics.shared.fire(.shortcut)
            action()
        }
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
