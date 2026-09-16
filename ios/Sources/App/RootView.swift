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
    /// Reader mode's one object (#008BC). Owned here because the reader is a
    /// layer over the whole window rather than something inside a tab, and
    /// because extraction has to reach the web view pool.
    @StateObject private var reader = ReaderController()
    /// The window's top safe-area inset, measured once at the root. The island
    /// is hardware, so this stays whatever the status bar is doing (#008A9).
    @State private var safeAreaTop: CGFloat = 0

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
        .modifier(
            RootNotifications(
                state: state, pool: pool.pool, compactBar: compactBar, reader: reader))
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
        if state.isSidebarVisible { return true }
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

    /// Where the page starts. Hiding the status bar is not an input — see
    /// `PageTopInsets` (#008A9). `.container` rather than `.all` where the page
    /// *does* take the top band keeps the keyboard pushing the layout, and
    /// releasing only the top edge leaves the horizontal insets intact, which
    /// is exactly where the Dynamic Island intrudes in landscape.
    private var topInsets: PageTopInsets {
        PageTopInsets.forSettings(state.settings, safeAreaTop: safeAreaTop)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let space = state.activeSpace {
                ContentArea(
                    state: state, space: space, pool: pool.pool,
                    topContentInset: topInsets.webTopContentInset
                )
                .padding(.horizontal, ZenMetrics.splitGap)
                .padding(.top, topInsets.cardTopPadding)
                .ignoresSafeArea(
                    .container, edges: topInsets.pageUnderTopSafeArea ? .top : [])
                // Tapping the page puts the compact chrome away again.
                // Simultaneous so it never swallows a page tap.
                .simultaneousGesture(
                    TapGesture().onEnded { hideChrome() },
                    including: state.compactBarPhase != .hidden ? .all : .subviews)
            }

            VStack(spacing: 8) {
                if state.isFindBarVisible {
                    FindBar(state: state, pool: pool.pool)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bar
                    // The outgoing toolbar must not accept the grabber's drag.
                    .allowsHitTesting(barPhase == .expanded && (isPad || !state.isSidebarVisible))
                    .accessibilityHidden(barPhase == .hidden || (!isPad && state.isSidebarVisible))
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .animation(.easeInOut(duration: ZenTokens.hiddenToolbarTransition), value: barPhase)
            .animation(.easeInOut(duration: 0.2), value: state.isFindBarVisible)
        }
        // The reader covers the page completely (#008BC), so a VoiceOver rotor
        // must not be able to walk into it. This hides the chrome; the hosted
        // `WKWebView` underneath keeps its own UIKit accessibility tree
        // regardless, which SwiftUI has no say over — so the page's *text* is
        // still reachable, and making it not be would mean reaching into the
        // representable. Left as is: the page is the same document the reader
        // is showing, so the worst case is hearing it twice.
        .accessibilityHidden(state.isReaderOpen)
    }

    /// Expanded or gone — compact mode's two states (#008AF, #008DC). When it
    /// is gone, the grabber is the one and only way back; there is no
    /// intermediate pill standing above it.
    @ViewBuilder
    private var bar: some View {
        switch barPhase {
        case .expanded:
            OmniboxPill(state: state) { shareItem = state.activeTab?.url }
                // Any touch on the bar keeps it, for as long as you are on it.
                .simultaneousGesture(TapGesture().onEnded { compactBar.barInteracted() })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .hidden:
            EmptyView()
        }
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

        ZenToastOverlay(message: $state.toast)
            .zIndex(4)
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
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { _ in Haptics.shared.prepare(.grabberDrag) }
                            .exclusively(before: TapGesture())
                            .onEnded { gesture in
                                switch gesture {
                                case .second:
                                    revealChrome()
                                case .first(let value):
                                    // Pull up to reveal; a downward flick belongs to Home.
                                    if value.translation.height < -8 {
                                        Haptics.shared.fire(.grabberDrag)
                                        revealChrome()
                                    }
                                }
                            }
                    )
                    .accessibilityLabel("Show toolbar")
                    .accessibilityAction { revealChrome() }
                    .accessibilityAddTraits(.isButton)
            }
            .transition(.opacity)
            .zIndex(1)
        }
    }

    // MARK: Reader mode (#008BC)

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

    /// The grabber's deliberate reveal: straight to the full bar, then the
    /// same still-timer as everything else.
    private func revealChrome() { compactBar.grabberRevealed() }

    /// Tapping the page puts the chrome away now rather than on the timer.
    private func hideChrome() { compactBar.pageTapped() }

    /// Which edge the reveal swipe starts from, and which way a dismiss swipe
    /// goes, both follow `sidebarEdge` — the gesture always opens toward the
    /// drawer's actual edge and closes back toward it.
    private var drawerEdgeSwipe: some Gesture {
        let edge = state.settings.sidebarEdge
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

/// The notifications the root has to answer — reload, the scroll signal that
/// drives compact mode, and the explicit hide. Its own layer for two reasons:
/// `RootView`'s modifier chain is at the type checker's limit, and these four
/// are one subject rather than four.
private struct RootNotifications: ViewModifier {
    @ObservedObject var state: BrowserState
    let pool: WebViewPool
    @ObservedObject var compactBar: CompactBarController
    @ObservedObject var reader: ReaderController

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .zenReloadActiveTab)) { _ in
                reloadActiveTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zenToggleReaderView)) { _ in
                toggleReader()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zenHideRevealedChrome)) { _ in
                compactBar.pageTapped()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zenPopOutVideo)) { _ in
                popOutVideo()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zenPageScrollBegan)) { _ in
                // Nothing may buzz during a scroll — see `Haptics.isScrolling`.
                Haptics.shared.isScrolling = true
                compactBar.pageDidScroll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zenPageScrollEnded)) { _ in
                Haptics.shared.isScrolling = false
                compactBar.scrollDidEnd()
            }
    }

    /// Open the reader on the active tab, or close it (#008BC).
    ///
    /// This is where the 90 KB of Readability is finally evaluated — on the
    /// press, not on page load. Extraction is asynchronous because it runs in
    /// the page's own process, so the button reports "working" and then either
    /// a reader or a reason.
    private func toggleReader() {
        guard !state.isReaderOpen else {
            withAnimation(.easeInOut(duration: 0.22)) { state.readerTabID = nil }
            reader.close()
            return
        }
        guard let tabID = state.activeTabID, let view = pool.existing(for: tabID) else {
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

    /// Ask the active page to pop its video out (#008B0). Only the root can:
    /// the menus that offer the action cannot reach the web view pool.
    private func popOutVideo() {
        guard let tabID = state.activeTabID, let view = pool.existing(for: tabID) else {
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

    private func reloadActiveTab() {
        guard let tabID = state.activeTabID else { return }
        // An unloaded tab has no view to reload; selecting it rebuilds one.
        guard let view = pool.existing(for: tabID) else {
            state.select(tabID)
            return
        }
        // A failed load has nothing committed, so reload() is a no-op;
        // clearing the guard lets the URL be requested again.
        if state.tab(id: tabID)?.loadFailure != nil {
            view.lastRequestedURL = nil
            state.updateTab(tabID) { $0.loadFailure = nil }
        } else {
            view.reload()
        }
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
            .onChange(of: state.settings.compactModeEnabled) { _, _ in sync() }
            .onChange(of: state.settings.compactHideDelay) { _, _ in sync() }
            .onChange(of: controller.phase) { _, phase in state.compactBarPhase = phase }
            // Selected chrome stays open through covering and uncovering.
            .onChange(of: isCovered) { _, covered in
                controller.coveredDidChange(covered)
            }
    }

    /// The page is not what you are looking at right now.
    private var isCovered: Bool {
        state.isOmniboxOpen || state.isSettingsPresented || state.isHistorySheetPresented
            || state.isSidebarVisible
    }

    /// The machine runs whenever compact mode is on, whichever halves of the
    /// chrome it hides — `RootView.barPhase` is what decides whether the
    /// *toolbar* follows it.
    private func sync() {
        controller.stillDelay = state.settings.compactHideDelay
        controller.coveredDidChange(isCovered)
        controller.isEnabled = state.settings.compactModeEnabled
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
