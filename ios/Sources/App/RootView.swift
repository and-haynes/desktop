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
    /// Experimental (#008AD). Always built — it is inert until a vault is
    /// configured, and having it unconditionally means the settings screen can
    /// offer to connect one.
    @StateObject private var vault = PasswordVaultService()
    /// Experimental (#008B8). Built unconditionally for the same reason the
    /// vault is: the settings screen has to be able to offer it, and below
    /// iOS 18.4 it simply never creates a runtime.
    @StateObject private var extensions = ExtensionHost.shared
    @StateObject private var pool = PoolBox()
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var shareItem: URL?
    /// Compact mode's three-state machine (#008AF). Owned here because only
    /// the root sees the page-scroll notifications and the grabber at once.
    @StateObject private var compactBar = CompactBarController()
    /// The page-stepping buttons' own show/hide machine (#008B9). Owned here
    /// for the same reason the compact bar is: only the root sees the
    /// page-scroll notifications.
    @StateObject private var navigationHelper = NavigationHelperController()
    /// Reader mode's one object (#008BC). Owned here because the reader is a
    /// layer over the whole window rather than something inside a tab, and
    /// because extraction has to reach the web view pool.
    @StateObject private var reader = ReaderController()
    /// The window's top safe-area inset, measured once at the root. The content
    /// ignores the safe area in two of the three layouts, so the web view needs
    /// the number explicitly to keep the page's own header out from under the
    /// clock.
    @State private var safeAreaTop: CGFloat = 0
    @State private var safeAreaBottom: CGFloat = 0
    @State private var focusToastTask: Task<Void, Never>?
    /// Set when the app leaves the foreground while Focus is on, so returning
    /// can demand authentication.
    @State private var focusNeedsUnlockOnReturn = false
    /// The bar was put away deliberately — a swipe assigned to `hideBar`, which
    /// is auto-hide's manual equivalent. Cleared by the grabber.
    @State private var barHiddenByGesture = false
    /// The `onScroll` auto-hide rule has the bar out of the way right now.
    @State private var barHiddenByScroll = false
    @State private var barRevealTask: Task<Void, Never>?
    /// The window is wider than it is tall, which is what the layout's
    /// landscape overrides key off.
    @State private var isLandscape = false

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

    /// The page tint only applies in Sepia — the setting is meaningless
    /// anywhere else, and leaving it armed would warm every page the moment
    /// someone switched back.
    private var tintsPages: Bool { palette.isSepia && state.settings.sepiaTintsPages }
    private var isPad: Bool { sizeClass == .regular }

    /// Compact mode has the chrome away — anything short of the full bar.
    private var chromeHidden: Bool {
        state.display.compactModeEnabled && compactBar.phase != .expanded
    }

    /// Which of compact mode's three states the bar is in (#008AF).
    /// `expanded` whenever compact mode's toolbar half is off, so everything
    /// below reads one value and never the setting.
    private var barPhase: CompactBarPhase {
        guard state.display.compactModeEnabled, state.settings.compactHidesToolbar else {
            return .expanded
        }
        return compactBar.phase
    }

    /// The collapsed pill stands in for the bar rather than nothing at all —
    /// but only where *compact mode* is what put the bar away. A bar hidden by
    /// a deliberate `hideBar` gesture stays hidden; that is what deliberate
    /// means.
    private var showsCompactPill: Bool {
        barPhase == .pill && !barHiddenByGesture
    }
    private var sidebarHidden: Bool {
        chromeHidden && state.settings.compactHidesSidebar
    }
    private var toolbarHidden: Bool {
        chromeHidden && state.settings.compactHidesToolbar
    }

    private var layoutMode: BrowserLayout { state.display.layout }

    // MARK: The customisable bar (#00896)

    private var barLayout: BarLayout { state.display.barLayout }
    private var barPosition: BarPosition { barLayout.position(landscape: isLandscape) }
    private var barAutoHide: BarAutoHide { barLayout.autoHide(landscape: isLandscape) }
    /// One line or two (#008BA). Landscape can collapse it back, which is
    /// what the setting exists for.
    private var barRows: BarRows { barLayout.rows(landscape: isLandscape) }
    /// How much of the screen the bar occupies — *not* `barLayout.height`,
    /// which is only the address line once there are two.
    private var barExtent: CGFloat { CGFloat(barLayout.totalHeight(rows: barRows)) }

    /// Whether the bar sits over the page rather than taking room from it. The
    /// full-screen *layout* floats it regardless of position, because that is
    /// the whole of what full screen means.
    private var barFloats: Bool { barPosition.isFloating || layoutMode.barFloats }

    /// The single answer to "is the bar on screen", from three rules that can
    /// each hide it: compact mode, the auto-hide setting, and a deliberate
    /// hide-bar gesture.
    private var barHidden: Bool {
        if barHiddenByGesture { return true }
        switch barAutoHide {
        case .never: return toolbarHidden
        case .onScroll: return toolbarHidden || barHiddenByScroll
        case .compact:
            // Follow compact mode whether or not it is switched on, which is
            // what makes this rule different from `never`.
            return state.settings.compactHidesToolbar && compactBar.phase != .expanded
        }
    }

    /// The grabber is the way back from *any* of those, not just compact mode.
    private var showsGrabber: Bool {
        chromeHidden || barHiddenByGesture
            || (barAutoHide == .compact && barHidden)
    }

    /// The bar can now carry back, forward, stop and scroll-to-top (#00896),
    /// and every one of those needs the *pool* — which only this view has. They
    /// arrive as notifications for the same reason `.zenReloadActiveTab` always
    /// did, and they are applied in their own layer because a single `body` with
    /// every modifier on it is more than the type-checker will sit still for.
    var body: some View {
        pageChrome
            .onReceive(NotificationCenter.default.publisher(for: .zenNavigateBack)) { note in
                webView(for: note)?.goBack()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zenNavigateForward)) { note in
                webView(for: note)?.goForward()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zenStopLoading)) { note in
                webView(for: note)?.stopLoading()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zenScrollToTop)) { note in
                guard let view = webView(for: note) else { return }
                let top = -view.scrollView.contentInset.top
                view.scrollView.setContentOffset(CGPoint(x: 0, y: top), animated: true)
            }
            .modifier(ExtensionBridge(state: state, host: extensions))
            .modifier(ExtensionOpenURLBridge(state: state, host: extensions, palette: palette))
    }

    private var window: some View {
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
            .onChange(of: proxy.size) { _, size in isLandscape = size.width > size.height }
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
            pool.pool.sepiaTintsPages = tintsPages
            // The runtime holds the browser weakly, so this is the one place
            // the two are introduced — the same shape as `sync.attach` below
            // and `pool.vault` above (#008B8).
            pool.pool.extensions = extensions
            extensions.start(state: state, pool: pool.pool)
            // A restored session has icons for nothing it has not yet loaded;
            // fetch them so the sidebar is not a column of monograms.
            Task { await FaviconService.prefetchMissing(for: state) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenReloadActiveTab)) { note in
            guard let tabID = tabID(for: note) ?? state.activeTabID else { return }
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
        .onReceive(NotificationCenter.default.publisher(for: .zenPopOutVideo)) { note in
            popOutVideo(webView(for: note))
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenToggleReaderView)) { _ in
            toggleReader()
        }
        .modifier(CompactBarBridge(state: state, controller: compactBar))
        .onReceive(NotificationCenter.default.publisher(for: .zenPageScrollBegan)) { _ in
            // Nothing may buzz during a scroll — see `Haptics.isScrolling`.
            Haptics.shared.isScrolling = true
            revealChromeWhileScrolling()
            barScrollBegan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenPageScrollEnded)) { _ in
            Haptics.shared.isScrolling = false
            scheduleCompactHide()
            barScrollEnded()
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .zenCycleLayout)) { _ in
            cycleLayout()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenToggleFocusMode)) { _ in
            Task { await toggleFocusMode() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenFocusErased)) { note in
            // Tear down the content processes behind the erased tabs. Dropping
            // the model alone would leave live web views holding the session.
            let ids = (note.userInfo?["tabs"] as? [String])?.compactMap(UUID.init(uuidString:))
            for id in ids ?? [] { pool.pool.unload(id) }
        }
        .onChange(of: state.focusToast) { _, message in
            guard message != nil else { return }
            focusToastTask?.cancel()
            focusToastTask = Task {
                try? await Task.sleep(for: .seconds(2.6))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { state.focusToast = nil }
            }
        }
        .onChange(of: tintsPages) { _, tint in
            pool.pool.sepiaTintsPages = tint
        }
        .onChange(of: scenePhase) { _, phase in
            // Flush the session on the way out; a jetsam gives no warning.
            if phase != .active { state.saveNow() }
            if phase == .active {
                sync.start()
                // Throttled inside the service: coming back to the foreground
                // repeatedly must not mean a KDF run each time (#008AD).
                pool.pool.vault = vault
                Task { await vault.syncIfStale() }
            } else {
                sync.applicationDidEnterBackground()
            }
            // A haptic fired from a background task is a phantom buzz in
            // someone's pocket.
            Haptics.shared.isForeground = phase == .active
            if phase == .active { Haptics.shared.prepare(Self.warmEvents) }
            switch phase {
            case .active:
                if focusNeedsUnlockOnReturn {
                    focusNeedsUnlockOnReturn = false
                    // Fail open when the device cannot authenticate at all —
                    // being locked out of your own tabs is a worse outcome.
                    if FocusLock.isAvailable { state.focusLocked = true }
                }
            case .inactive, .background:
                if state.isFocusMode && state.settings.focusRequiresBiometrics {
                    focusNeedsUnlockOnReturn = true
                }
            @unknown default:
                break
            }
        }
    }

    /// Page-level behaviours that need both the pool and a store — page zoom
    /// so far (#008B7). Its own layer for the same reason the sheets are:
    /// `body` is already as long an expression as the type checker will solve.
    private var pageChrome: some View {
        sheets
            .modifier(PageZoomBridge(state: state, pool: pool.pool))
            .modifier(
                NavigationHelperBridge(
                    state: state, helper: navigationHelper, pool: pool.pool))
    }

    /// The sheets, in one layer of their own.
    ///
    /// Not a style choice: `body` had grown past what the type-checker will
    /// solve in reasonable time, and splitting it is the documented remedy.
    /// They stay together and in this order because the certificate prompt is
    /// *gated* against the others — see the binding below — and that gate reads
    /// `isBlockingSheetPresented`, which has to know about all of them.
    private var sheets: some View {
        window
            .sheet(isPresented: $state.isHistorySheetPresented) {
                HistorySheet(state: state, history: state.history, bookmarks: state.bookmarks)
                    .environment(\.zenPalette, palette)
            }
            .sheet(isPresented: $state.isSettingsPresented) {
                SettingsSheet(state: state, sync: sync, vault: vault, extensions: extensions)
                    .environment(\.zenPalette, palette)
            }
            .sheet(isPresented: $state.isLocalServicesPresented) {
                LocalSectionSheet(state: state).environment(\.zenPalette, palette)
            }
            .sheet(isPresented: $state.isPasswordsPanelPresented) {
                PasswordsPanel(state: state, vault: vault, pool: pool.pool)
                    .environment(\.zenPalette, palette)
            }
            .sheet(isPresented: $state.isExtensionsPanelPresented) {
                ExtensionsPanel(host: extensions, state: state)
                    .environment(\.zenPalette, palette)
            }
            // `item:`, not `isPresented:` — the sheet *is* the web view WebKit
            // handed us, and there is nothing to show without one.
            .sheet(item: $extensions.popup) { request in
                ExtensionPopupSheet(request: request, host: extensions)
                    .environment(\.zenPalette, palette)
            }
            // `item:`, not `isPresented:` — the sheet is built from the
            // credential, and a nil one would have nothing to show.
            .sheet(item: $vault.pendingSave) { credential in
                SavePasswordSheet(
                    credential: credential,
                    existing: vault.existingEntry(for: credential),
                    vault: vault
                )
                .environment(\.zenPalette, palette)
            }
            .sheet(item: $shareItem) { url in
                ShareSheet(items: [url])
            }
            // Root level, so it covers a split pane or a glance card — neither can
            // present anything that covers the window. The binding is *gated*
            // rather than direct: SwiftUI silently drops a second sheet presented
            // from the same view while one is up, so a challenge raised while
            // Settings or History is open would simply never appear, leaving the
            // page blocked on a question nobody was asked. Gating queues it instead
            // — it surfaces the moment the other sheet closes.
            //
            // The setter is deliberately inert. Gating dismisses the sheet by
            // returning nil from the getter, and a setter that wrote that back
            // would throw the challenge away; the only way out is answering it.
            .sheet(
                item: Binding(
                    get: { state.isBlockingSheetPresented ? nil : state.pendingCertificateChallenge },
                    set: { _ in })
            ) { challenge in
                CertificateSheet(
                    challenge: challenge,
                    onTrust: { state.resolveCertificateChallenge(.trust) },
                    onReject: { state.resolveCertificateChallenge(.reject) }
                )
                .environment(\.zenPalette, palette)
            }
            .sheet(item: $state.securityDetail) { detail in
                SecurityDetailSheet(detail: detail, state: state)
                    .environment(\.zenPalette, palette)
            }
            // Page-level behaviours that need both the pool and a store — page
            // zoom so far (#008B7). Its own modifier for the same reason the rest
            // of this chain is split into helpers: `body` is already as long an
            // expression as the type checker will solve.
            .modifier(PageZoomBridge(state: state, pool: pool.pool))
            .background { keyboardShortcuts }
    }

    // MARK: Background

    private var background: some View {
        ZStack {
            if let space = state.activeSpace {
                ZenGradientView(theme: space.theme, isDark: palette.isDark)
                    .id(space.id)
                    .transition(.opacity)
                // Sepia keeps the space's gradient — it is still how you tell
                // one space from another — but pulls it most of the way to
                // paper. A vivid purple wash behind warm paper chrome would
                // undo the whole point of the scheme.
                if palette.isSepia {
                    ZenTokens.sepiaPaper.withAlpha(0.82).color
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
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
        let edge = state.display.sidebarEdge
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
        let edge = state.display.sidebarEdge
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

    /// Where the page starts at the top, per the layout cycle. Hiding the
    /// status bar is deliberately not an input — see `PageTopInsets` (#008A9).
    private var topInsets: PageTopInsets {
        PageTopInsets.forDisplay(state.display, safeAreaTop: safeAreaTop)
    }

    /// Card keeps Zen's desktop inset; the other two layouts hand the page the
    /// top edge. This follows the layout, not the status bar.
    private var reclaimsTopEdge: Bool { topInsets.pageUnderTopSafeArea }

    /// The bar can now be at either end and either in the flow or over the
    /// page, which is four arrangements rather than two — so the alignment and
    /// the order are both read off the layout instead of being written out.
    private var content: some View {
        ZStack(alignment: barPosition.isTop ? .top : .bottom) {
            VStack(spacing: 0) {
                // Docked at the top the bar takes room from the page, exactly
                // as the bottom-docked one always has.
                if !barFloats && barPosition.isTop { barStack }
                contentArea
                if !barFloats && !barPosition.isTop { barStack }
            }
            // Floating: over the page, taking no part in the flow.
            if barFloats { barStack }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: layoutMode)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: barPosition)
        // A space can change any of those at once (#008BB), and a chrome that
        // jumped between two arrangements would read as a glitch rather than
        // as arriving somewhere.
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: state.activeSpaceID)
    }

    @ViewBuilder
    private var contentArea: some View {
        if let space = state.activeSpace {
            ContentArea(
                state: state, space: space, pool: pool.pool,
                topContentInset: webTopInset, bottomContentInset: webBottomInset,
                rounded: layoutMode.framesContent,
                navigationHelper: navigationHelper
            )
            .padding(.horizontal, layoutMode.framesContent ? ZenMetrics.splitGap : 0)
            .padding(
                .top,
                layoutMode.framesContent && !reclaimsTopEdge ? ZenMetrics.splitGap : 0)
            // `.container` rather than `.all`: the page should run under the
            // status bar, but the keyboard must still push the layout. Only the
            // top edge is released, so the horizontal insets the island takes
            // in landscape stay.
            .ignoresSafeArea(.container, edges: topEdgesIgnored)
            .animation(.easeInOut(duration: 0.25), value: state.settings.showStatusBar)
            // Tapping the page puts a revealed compact toolbar away again.
            // Simultaneous so it never swallows a tap meant for the page.
            .simultaneousGesture(
                TapGesture().onEnded {
                    hideChrome()
                    navigationHelper.pageTapped()
                },
                including: state.compactBarPhase != .hidden ? .all : .subviews)
        }
    }

    private var topEdgesIgnored: Edge.Set {
        // A bar docked at the top has already taken the safe area for itself,
        // so the page must not reclaim it as well — that would slide the page
        // up underneath the bar.
        let topTaken = !barFloats && barPosition.isTop
        switch layoutMode {
        case .card: return reclaimsTopEdge && !topTaken ? .top : []
        case .edgeToEdge: return topTaken ? [] : .top
        case .fullScreen: return topTaken ? .bottom : [.top, .bottom]
        }
    }

    /// The web view draws under the status bar in two of the three layouts, so
    /// give its scroll view an explicit top inset — the page's own header would
    /// otherwise sit under the clock. `contentInsetAdjustmentBehavior` stays
    /// `.never` so this is the only thing moving the content.
    ///
    /// With the status bar hidden (the default, #00899) there is no clock to
    /// keep clear of, and the strip an inset opens up cannot be painted in the
    /// page's own colour — so the page simply has the edge, and the island sits
    /// over it.
    private var webTopInset: CGFloat {
        var inset: CGFloat = 0
        // `PageTopInsets` owns the status-bar half of this (#008A9): the inset
        // is a function of the layout and the window's safe area, never of
        // whether the clock is showing. A bar *docked* at the top has already
        // taken the safe area, so the page must not be inset for it twice.
        if !(!barFloats && barPosition.isTop) {
            inset += topInsets.webTopContentInset
        }
        // A bar floating at the *top* covers the page's first screenful the
        // same way the bottom one covers its last.
        if barFloats, barPosition.isTop, !barHidden {
            inset += barExtent + topBarInset + 8
        }
        return inset
    }

    /// A floating bar sits over the page, so the screenful under it would be
    /// permanently covered without a matching inset.
    private var webBottomInset: CGFloat {
        guard barFloats, !barPosition.isTop, !barHidden else { return 0 }
        return barExtent + bottomBarInset + 12
    }

    private var barStack: some View {
        let edge: Edge = barPosition.isTop ? .top : .bottom
        // One container for both bars: two pieces of glass 8pt apart should
        // read as one lens, not as two stacked ones.
        return ZenGlassContainer(spacing: 8) {
            VStack(spacing: 8) {
                if state.isFindBarVisible {
                    FindBar(state: state, pool: pool.pool)
                        .transition(.move(edge: edge).combined(with: .opacity))
                }
                if !barHidden {
                    OmniboxPill(
                        state: state, isFloating: barFloats, isLandscape: isLandscape,
                        onShare: { shareItem = $0 },
                        onHideBar: { hideBarByGesture() },
                        extensions: extensions
                    )
                    // Any touch on the bar keeps it, for as long as you are on
                    // it. The customised layout is whatever `OmniboxPill`
                    // draws, so expanding the pill gives back *your* bar
                    // rather than a default one (#008AF).
                    .simultaneousGesture(TapGesture().onEnded { compactBar.barInteracted() })
                    .transition(.move(edge: edge).combined(with: .opacity))
                } else if showsCompactPill {
                    CompactPill(state: state) { compactBar.pillTapped() }
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                }
            }
        }
        // The margin is the layout's, except that a full-width bar keeps a
        // hairline of inset so its border is not clipped by the screen edge.
        .padding(.horizontal, max(CGFloat(barLayout.horizontalMargin), barLayout.isPill ? 4 : 0))
        .padding(.top, barPosition.isTop ? topBarInset : 8)
        .padding(.bottom, barPosition.isTop ? 4 : bottomBarInset)
        .animation(.easeInOut(duration: ZenTokens.hiddenToolbarTransition), value: barHidden)
        .animation(.easeInOut(duration: 0.2), value: state.isFindBarVisible)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: barRows)
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: state.activeSpaceID)
        // The reader covers the page completely (#008BC), so a VoiceOver rotor
        // must not be able to walk into it. This hides the chrome; the hosted
        // `WKWebView` underneath keeps its own UIKit accessibility tree
        // regardless, which SwiftUI has no say over — so the page's *text* is
        // still reachable, and making it not be would mean reaching into the
        // representable. Left as is: the page is the same document the reader
        // is showing, so the worst case is hearing it twice.
        .accessibilityHidden(state.isReaderOpen)
    }

    /// The bar's own vertical offset, on top of whatever the safe area needs.
    private var barOffset: CGFloat { CGFloat(barLayout.verticalOffset) }

    private var topBarInset: CGFloat {
        (barFloats || reclaimsTopEdge ? safeAreaTop : 0) + barOffset
    }

    private var bottomBarInset: CGFloat {
        (barFloats ? safeAreaBottom : 0) + barOffset
    }

    // MARK: Overlays

    @ViewBuilder
    private var overlays: some View {
        // Over everything but the toast: the reader *replaces* the page for as
        // long as it is up, and a glance card or an omnibox belonging to the
        // page underneath would be showing through something you have left.
        if state.readerTabID != nil, reader.article != nil, let space = state.activeSpace {
            ReaderView(
                state: state, reader: reader, space: space,
                onClose: { closeReader() },
                onOpenLink: { url in openFromReader(url) }
            )
            .environment(\.zenPalette, palette)
            // A new article is a new document, not a restyle of the old one.
            .id(reader.article?.url?.absoluteString ?? "reader")
            .zIndex(3.5)
        }

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

        if let message = state.focusToast {
            VStack {
                Spacer()
                FocusToast(message: message)
                    .padding(.bottom, ZenMetrics.omniboxPillHeight + 28)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(false)
            .zIndex(4)
        }

        ZenToastOverlay(message: $state.toast)
            .zIndex(6)

        // Above everything, including the omnibox — the point is that nothing
        // from the session is readable until the owner authenticates.
        if state.focusLocked {
            FocusLockScreen(state: state)
                .environment(\.zenPalette, palette)
                .transition(.opacity)
                .zIndex(5)
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
        if showsGrabber {
            VStack {
                // The handle goes to whichever edge the bar it summons lives on.
                if barPosition.isTop {
                    grabberPill
                    Spacer()
                } else {
                    Spacer()
                    grabberPill
                }
            }
            .transition(.opacity)
            .zIndex(1)
        }
    }

    private var grabberPill: some View {
        Capsule()
            .fill(palette.text.withAlpha(0.75).color)
            .frame(
                width: ZenMetrics.compactGrabberWidth,
                height: ZenMetrics.compactGrabberHeight)
            // The page behind can be any colour, and a bare 35%-alpha pill
            // simply vanished against a light one. A material pad behind it
            // gives the handle something to sit on, the way a system sheet
            // grabber does.
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
                        // Pull *away from the edge the bar is on* to reveal; the
                        // other direction is the user reaching for the home
                        // gesture (or the notification shade).
                        let towardsCentre =
                            barPosition.isTop ? value.translation.height > 8
                            : value.translation.height < -8
                        if towardsCentre {
                            Haptics.shared.fire(.grabberDrag)
                            revealChrome()
                        }
                    }
            )
            .accessibilityLabel("Show toolbar")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Reader mode (#008BC)

    /// Open the reader on the active tab, or close it. This is where the
    /// 90 KB of Readability is finally evaluated — on the press, not on page
    /// load. Extraction is asynchronous because it runs in the page's own
    /// process, so the button reports "working" and then either a reader or
    /// a reason.
    private func toggleReader() {
        guard !state.isReaderOpen else {
            closeReader()
            return
        }
        guard let tabID = state.activeTabID, let view = pool.pool.existing(for: tabID) else {
            state.toast = ZenToastMessage("No page to read.", symbol: "doc.plaintext")
            return
        }
        state.isExtractingReader = true
        view.extractArticle { article in
            state.isExtractingReader = false
            guard let article else {
                Haptics.shared.fire(.loadError)
                state.toast = ZenToastMessage(
                    "No article to read on this page.", symbol: "doc.plaintext")
                // An extraction that came back empty is the honest answer to
                // the probe as well; leaving the button up invites a second
                // press with the same result.
                state.setReaderAvailable(false, for: tabID)
                return
            }
            Haptics.shared.fire(.glanceOpen)
            reader.open(article, defaults: state.settings.readerDefaults)
            withAnimation(.easeInOut(duration: 0.22)) { state.readerTabID = tabID }
        }
    }

    /// Leaving the reader is removing a layer. The tab's own web view has been
    /// sitting underneath the whole time — same scroll offset, same history —
    /// so there is no position to restore and nothing that can fail to.
    private func closeReader() {
        withAnimation(.easeInOut(duration: 0.22)) { state.readerTabID = nil }
        reader.close()
    }

    /// A link tapped in an article means "go there", and going there means the
    /// browser: a second article rendered inside the reader would have no
    /// address bar, no back gesture and no way out.
    private func openFromReader(_ url: URL) {
        closeReader()
        state.newTab(url: url)
    }

    /// The grabber's deliberate reveal: no countdown, it stays until the page
    /// is tapped or scrolled.
    private func revealChrome() {
        barRevealTask?.cancel()
        barRevealTask = nil
        compactBar.grabberRevealed()
        withAnimation(
            .spring(response: ZenMetrics.compactAnimationDuration * 2, dampingFraction: 1)
        ) {
            // The grabber is the way back from every rule that can hide the
            // bar, so it clears all of them rather than just compact mode's.
            barHiddenByGesture = false
            barHiddenByScroll = false
        }
    }

    /// The `hideBar` action — auto-hide's manual equivalent. Deliberate, so it
    /// stays put until the grabber brings it back.
    private func hideBarByGesture() {
        barRevealTask?.cancel()
        barRevealTask = nil
        Haptics.shared.fire(.compactBarHide)
        withAnimation(.easeInOut(duration: ZenTokens.hiddenToolbarTransition)) {
            barHiddenByGesture = true
        }
    }

    /// The `onScroll` rule: out of the way while the page is moving, back
    /// shortly after it settles.
    ///
    /// Direction would be nicer — Safari hides going down and shows going up —
    /// but WKWebView's scroll delegate reaches us as a notification with no
    /// payload, and threading direction through it would mean a second channel
    /// for one animation. "Moving" is the honest signal we have, and it reuses
    /// the compact-mode delay that already exists as a setting.
    private func barScrollBegan() {
        guard barAutoHide == .onScroll else { return }
        barRevealTask?.cancel()
        barRevealTask = nil
        guard !barHiddenByScroll else { return }
        withAnimation(.easeOut(duration: ZenTokens.hiddenToolbarTransition)) {
            barHiddenByScroll = true
        }
    }

    private func barScrollEnded() {
        guard barAutoHide == .onScroll, barHiddenByScroll else { return }
        barRevealTask?.cancel()
        let delay = max(0.2, state.settings.compactHideDelay)
        barRevealTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: ZenTokens.hiddenToolbarTransition)) {
                barHiddenByScroll = false
            }
        }
    }

    /// Scrolling brings the bar back for as long as you keep scrolling. Each
    /// scroll event restarts the countdown, so a long flick does not flicker.
    /// Scrolling brings back the *pill* and only the pill — a full toolbar for
    /// every flick is the noise compact mode exists to remove (#008AF).
    private func revealChromeWhileScrolling() {
        compactBar.pageDidScroll()
    }

    /// Start the fade-out countdown. Cancelled by any further scrolling, so
    /// the bar only goes when the page has actually settled.
    /// Scrolling settled; everything from here is the still-timer.
    private func scheduleCompactHide() {
        compactBar.scrollDidEnd()
    }

    /// The reveal is momentary: tapping the page or scrolling puts it back.
    /// There is no auto-hide timer — a deliberate reveal should not time out.
    private func hideChrome() {
        compactBar.pageTapped()
    }

    /// Ask a page to pop its video out (#008B0). Only the root can: the bar
    /// action and the context menu that offer it cannot reach the pool.
    private func popOutVideo(_ webView: ZenWebView?) {
        guard let view = webView else {
            state.toast = ZenToastMessage("No page to pop out.", symbol: "pip.exit")
            return
        }
        Haptics.shared.fire(.layoutChange)
        view.popOutVideo { result in
            // Success says so by itself — the video visibly leaves the page.
            guard let message = result.message else { return }
            Haptics.shared.fire(.loadError)
            state.toast = ZenToastMessage(message, symbol: "pip.exit")
        }
    }

    /// The tab a bar-action notification names, or nil for "whatever is
    /// active" — which is what `.zenReloadActiveTab` has always meant.
    private func tabID(for note: Notification) -> UUID? {
        (note.userInfo?["tab"] as? String).flatMap(UUID.init(uuidString:))
    }

    /// The live web view a bar-action notification is about. Only RootView can
    /// answer this, because only it holds the pool.
    private func webView(for note: Notification) -> ZenWebView? {
        guard let id = tabID(for: note) ?? state.activeTabID else { return nil }
        return pool.pool.existing(for: id)
    }

    private func readSafeArea(_ proxy: GeometryProxy) {
        safeAreaTop = proxy.safeAreaInsets.top
        safeAreaBottom = proxy.safeAreaInsets.bottom
        isLandscape = proxy.size.width > proxy.size.height
    }

    /// Entering Focus compiles the blocklist *before* creating the first tab —
    /// a tab made without it would load trackers on its first navigation, which
    /// is exactly the promise the mode makes.
    @MainActor
    private func toggleFocusMode() async {
        if state.isFocusMode {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                state.exitFocusMode()
            }
            pool.pool.focusBlocklist = nil
            return
        }
        pool.pool.focusBlocklist = await ContentBlocker.focusRuleList()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            // `enterFocusMode` returns the new space; nothing here wants it,
            // and `@discardableResult` does not survive the closure.
            _ = state.enterFocusMode()
        }
    }

    /// Advance the layout cycle. Shared by the overflow menu and Cmd-Shift-F.
    private func cycleLayout() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            state.setLayout(state.display.layout.next)
        }
    }

    /// Which edge the reveal swipe starts from, and which way a dismiss swipe
    /// goes, both follow `sidebarEdge` — the gesture always opens toward the
    /// drawer's actual edge and closes back toward it.
    private var drawerEdgeSwipe: some Gesture {
        let edge = state.display.sidebarEdge
        return DragGesture(minimumDistance: 20)
            .onChanged { _ in Haptics.shared.prepare(.sidebarSnap) }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let opens: Bool
                let closes: Bool
                switch edge {
                case .leading:
                    opens = value.startLocation.x < 24 && value.translation.width > 40
                    closes = value.translation.width < -40
                case .trailing:
                    opens =
                        value.startLocation.x > UIScreen.main.bounds.width - 24
                        && value.translation.width < -40
                    closes = value.translation.width > 40
                }
                if opens {
                    Haptics.shared.fire(.sidebarSnap)
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        state.isSidebarVisible = true
                    }
                } else if state.isSidebarVisible && closes {
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
            shortcutButton("f", modifiers: [.command, .shift]) { cycleLayout() }
            shortcutButton("p", modifiers: [.command, .shift]) {
                Task { await toggleFocusMode() }
            }
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
            // ⌘+ / ⌘− / ⌘0, in a view of their own — see `PageZoomShortcuts`.
            PageZoomShortcuts()
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

/// Keeps the extension runtime told about the tabs (#008B8).
///
/// `tabs.query`, `tabs.onUpdated` and `tabs.onActivated` are all answered out
/// of `BrowserState`, so the runtime has to be nudged whenever the model moves.
/// A separate layer for the same reason `CompactBarBridge` is one: `RootView`'s
/// own modifier chain is already as much as the type checker will solve.
///
/// Driven from the *view* rather than by subscribing to the model inside the
/// runtime, because `BrowserState` publishes on every keystroke in the URL bar
/// and an extension has no business hearing about those.
private struct ExtensionBridge: ViewModifier {
    @ObservedObject var state: BrowserState
    @ObservedObject var host: ExtensionHost

    func body(content: Content) -> some View {
        content
            .onChange(of: state.tabs) { _, _ in host.tabsChanged() }
            .onChange(of: state.activeTabID) { _, _ in host.tabsChanged() }
            .onChange(of: state.activeSpaceID) { _, _ in host.tabsChanged() }
            .onChange(of: state.navigationStates) { _, _ in host.tabsChanged() }
    }
}

/// Keeps the compact-bar machine fed — the settings it runs on going in, the
/// phase the rest of the tree reads coming out. A separate layer because
/// `RootView`'s own modifier chain is already at the type checker's limit.
private struct CompactBarBridge: ViewModifier {
    @ObservedObject var state: BrowserState
    @ObservedObject var controller: CompactBarController

    func body(content: Content) -> some View {
        content
            .onAppear(perform: sync)
            .onChange(of: state.display.compactModeEnabled) { _, _ in sync() }
            .onChange(of: state.settings.compactHideDelay) { _, _ in sync() }
            .onChange(of: controller.phase) { _, phase in state.compactBarPhase = phase }
            // Anything covering the page pauses the countdown and hands the bar
            // back whole on the way out — see `coveredDidChange`.
            .onChange(of: isCovered) { _, covered in
                controller.coveredDidChange(covered)
            }
    }

    /// The page is not what you are looking at right now.
    private var isCovered: Bool {
        state.isOmniboxOpen || state.isSettingsPresented || state.isHistorySheetPresented
            || state.isSidebarVisible || state.focusLocked
    }

    /// The machine runs whenever compact mode is on, whichever halves of the
    /// chrome it hides — `RootView.barPhase` is what decides whether the
    /// *toolbar* follows it.
    private func sync() {
        controller.stillDelay = state.settings.compactHideDelay
        controller.isEnabled = state.display.compactModeEnabled
        state.compactBarPhase = controller.phase
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
