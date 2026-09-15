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
    @StateObject private var sync: SyncService
    @StateObject private var pool = PoolBox()
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var shareItem: URL?
    /// The compact bar's three-state machine (#008AF). Owned here because only
    /// the root sees the page-scroll notifications and the grabber at once.
    @StateObject private var compactBar = CompactBarController()
    /// The window's safe-area insets, measured once at the root. The content
    /// ignores the safe area in two of the three layouts, so the web view needs
    /// the numbers explicitly to keep the page's own header out from under the
    /// clock — and the island is hardware, so the top one stays whatever the
    /// status bar is doing (#008A9).
    @State private var safeAreaTop: CGFloat = 0
    @State private var safeAreaBottom: CGFloat = 0

    @MainActor
    init(state: BrowserState? = nil, sync: SyncService? = nil) {
        // Built lazily inside the autoclosure so restoring the session
        // happens when the scene appears, not while the view tree is built.
        let restored = state
        _state = StateObject(wrappedValue: restored ?? BrowserState())
        let service = sync
        _sync = StateObject(wrappedValue: service ?? SyncService())
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

    /// What the bar is showing. `expanded` whenever compact mode's toolbar
    /// half is off, so every view below reads one value and never the setting.
    private var barPhase: CompactBarPhase {
        guard state.settings.compactModeEnabled, state.settings.compactHidesToolbar else {
            return .expanded
        }
        return compactBar.phase
    }

    /// Compact mode has the chrome away — anything short of the full bar.
    private var chromeHidden: Bool {
        state.settings.compactModeEnabled && compactBar.phase != .expanded
    }
    private var sidebarHidden: Bool {
        chromeHidden && state.settings.compactHidesSidebar
    }
    /// Nothing at all where the bar is: the pill still counts as chrome.
    private var toolbarHidden: Bool { barPhase == .hidden }

    private var layoutMode: BrowserLayout { state.settings.layout }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background
                layout
                compactGrabber
                overlays
            }
            .onAppear { readSafeArea(proxy) }
            .onChange(of: proxy.safeAreaInsets.top) { _, _ in readSafeArea(proxy) }
            .onChange(of: proxy.safeAreaInsets.bottom) { _, _ in readSafeArea(proxy) }
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
        .modifier(RootNotifications(state: state, pool: pool.pool, compactBar: compactBar))
        .task {
            // The service holds the browser weakly, so this is the one place
            // the two are introduced.
            sync.attach(to: state)
            sync.start()
        }
        .onChange(of: state.tabs) { _, _ in
            // Stamp the change journal at the moment the change happens, so an
            // edit made offline carries an honest timestamp into the merge.
            sync.noteLocalChange()
        }
        .onChange(of: state.spaces) { _, _ in sync.noteLocalChange() }
        .modifier(CompactBarBridge(state: state, controller: compactBar))
        .onReceive(NotificationCenter.default.publisher(for: .zenCycleLayout)) { _ in
            cycleLayout()
        }
        .onChange(of: scenePhase) { _, phase in
            // Flush the session on the way out; a jetsam gives no warning.
            if phase != .active { state.saveNow() }
            if phase == .active {
                sync.start()
            } else {
                sync.applicationDidEnterBackground()
            }
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
            SettingsSheet(state: state, sync: sync).environment(\.zenPalette, palette)
        }
        .sheet(item: $shareItem) { url in
            ShareSheet(items: [url])
        }
        .sheet(item: $state.pendingCertificateChallenge) { challenge in
            CertificateSheet(
                challenge: challenge,
                onTrust: { state.resolveCertificateChallenge(.trust) },
                onReject: { state.resolveCertificateChallenge(.reject) }
            )
            .environment(\.zenPalette, palette)
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
        let edge = state.settings.sidebarEdge
        return HStack(spacing: 0) {
            if edge == .leading, showPadSidebar { padSidebar(edge: edge) }
            content
            if edge == .trailing, showPadSidebar { padSidebar(edge: edge) }
        }
        .animation(
            .spring(response: ZenMetrics.compactAnimationDuration * 2, dampingFraction: 1),
            value: showPadSidebar)
        .animation(
            .spring(response: ZenMetrics.compactAnimationDuration * 2, dampingFraction: 1),
            value: edge)
    }

    private func padSidebar(edge: SidebarEdge) -> some View {
        SidebarView(state: state, sync: sync)
            .frame(width: ZenMetrics.sidebarWidthPad)
            .transition(.move(edge: edge.swiftUIEdge).combined(with: .opacity))
    }

    private var showPadSidebar: Bool {
        guard state.settings.sidebarPinnedOnPad else { return state.isSidebarVisible }
        return !sidebarHidden
    }

    private var phoneLayout: some View {
        let edge = state.settings.sidebarEdge
        return ZStack(alignment: edge.alignment) {
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
                SidebarView(state: state, sync: sync)
                    .frame(width: ZenMetrics.sidebarWidthPhone)
                    .background {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay(palette.themedToolbarBG.withAlpha(0.22).color)
                            .ignoresSafeArea()
                    }
                    .zenBigShadow()
                    .transition(.move(edge: edge.swiftUIEdge))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: state.isSidebarVisible)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: edge)
        // Edge swipe to open the drawer, as the toolbar button does.
        .gesture(drawerEdgeSwipe)
    }

    /// With the status bar hidden there is nothing left in the top band but
    /// empty gradient, so even the card layout — which normally keeps Zen's
    /// desktop inset — gives the page the top edge.
    ///
    /// The island itself is hardware and simply sits over the page, as it does
    /// over video, photos and maps. The alternative — insetting the page by the
    /// island's height — needs a strip in the page's own background colour to
    /// look like anything but a black slab, and WebKit will not tell us that
    /// colour while the web view is transparent (which it must be, so the space
    /// gradient shows through before a page paints).
    private var reclaimsTopEdge: Bool { !state.settings.showStatusBar }

    private var content: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                contentArea
                // In card and edge-to-edge the bar is in the layout flow and
                // pushes the page up. In full screen it floats, so it must not
                // take part in the flow at all.
                if !layoutMode.barFloats { bottomBar }
            }
            if layoutMode.barFloats { bottomBar }
