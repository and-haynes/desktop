//  WebEngine.swift
//  Per-space WebKit data stores, and the pool that decides which tabs get to
//  hold a live WKWebView.
//
//  Zen isolates a space's cookies with a Firefox container. WebKit has no
//  containers, but iOS 17 gave us `WKWebsiteDataStore(forIdentifier:)` — a
//  persistent store with its own cookie jar, local storage, IndexedDB and
//  cache. One per space gives us the same guarantee: signing into an account in
//  Work does not sign you in in Personal.
//
//  The pool exists because a WKWebView costs a content process (tens of MB).
//  Holding one per tab would get the app jetsammed with a few dozen tabs open,
//  so inactive tabs are "unloaded": we drop the view, keep the URL, title,
//  favicon and scroll offset, and rebuild on next selection. That is exactly
//  what upstream's `unloadWorkspace()` does, except we do it automatically.

import Foundation
import UIKit
import WebKit

enum WebEngine {
    /// Cached so that two tabs in one space genuinely share a session.
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    /// Focus mode's store. `nonPersistent()` writes nothing to disk, and a
    /// fresh one is a genuinely fresh session — which is what "Erase" means.
    static func ephemeralDataStore() -> WKWebsiteDataStore { .nonPersistent() }

    static func dataStore(for space: Space) -> WKWebsiteDataStore {
        if let existing = stores[space.dataStoreID] { return existing }
        // `forIdentifier:` traps on the all-zero UUID, and a private-mode store
        // would silently discard logins between launches.
        let identifier = space.dataStoreID
        let store: WKWebsiteDataStore
        if identifier == UUID(uuidString: "00000000-0000-0000-0000-000000000000") {
            store = .default()
        } else {
            store = WKWebsiteDataStore(forIdentifier: identifier)
        }
        stores[space.dataStoreID] = store
        return store
    }

    /// Wipe a space's cookies and cache — used when a space is deleted so its
    /// data does not linger on disk.
    static func removeDataStore(for space: Space) {
        stores[space.dataStoreID] = nil
        WKWebsiteDataStore.remove(forIdentifier: space.dataStoreID) { _ in }
    }

    /// Safari's iOS UA, which is what sites expect from a WebKit browser, plus
    /// a Zen token so we are honest about who we are.
    static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1 Zen/0.1"

    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15 Zen/0.1"

    @MainActor
    static func configuration(
        for space: Space, desktop: Bool, ephemeral: Bool = false,
        blocklist: WKContentRuleList? = nil, sepiaTint: Bool = false
    ) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ephemeral ? ephemeralDataStore() : dataStore(for: space)
        if let blocklist {
            config.userContentController.add(blocklist)
        }
        config.defaultWebpagePreferences.preferredContentMode = desktop ? .desktop : .mobile
        config.applicationNameForUserAgent = "Zen/0.1"
        config.suppressesIncrementalRendering = false
        if sepiaTint {
            // At document end, so a new page comes up already warm instead of
            // flashing white and then tinting.
            config.userContentController.addUserScript(
                SepiaPageTint.userScript(enabled: true))
        }
        // Long-press link targets come from WKUIDelegate's
        // contextMenuConfigurationForElement, so no script injection is needed.
        applyMediaPolicy(to: config)
        //
        // Nothing is added to `userContentController` here, and that is a
        // feature (#008AB): a user script that rewrites login forms, renames
        // fields or intercepts focus is enough to stop iOS recognising them,
        // and Password AutoFill goes quiet with no error to explain it.
        return config
    }

    /// Video, in one place (#008B0).
    ///
    /// WebKit's defaults are conservative because the framework cannot know
    /// whether it is embedded in a browser or in a bank's login screen. A
    /// browser is exactly the case where the site's own judgement should win:
    /// every one of these is something Safari does and a page has every right
    /// to expect.
    ///
    /// The one that is not obvious is
    /// `mediaTypesRequiringUserActionForPlayback`. It was `.audio`, which
    /// sounds like the polite setting and is in fact the broken one: it makes
    /// *muted autoplay* — the silent looping clip that is half the modern web's
    /// page furniture — require a tap that will never come, so those elements
    /// sit black forever. Empty means "the page decides", and a page that
    /// wanted to blast audio at you already could by playing on first touch.
    @MainActor
    static func applyMediaPolicy(to config: WKWebViewConfiguration) {
        // Play in the page, not in a hijacked full-screen player.
        config.allowsInlineMediaPlayback = true
        // The PiP button in the native controls, and the API behind
        // `requestPictureInPicture()`.
        config.allowsPictureInPictureMediaPlayback = true
        // The page's own call. See above.
        config.mediaTypesRequiringUserActionForPlayback = []
        // `element.requestFullscreen()` — how YouTube and Vimeo's own controls
        // go full screen, as opposed to the native player.
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true

        // The page's half of the audio session (see `MediaSession`). Registered
        // here rather than per-view so there is one place that can be wrong,
        // and `.atDocumentEnd` because the listeners need a `document` to
        // attach to. `forMainFrameOnly: false` so a same-origin iframe — which
        // is how plenty of sites embed their own player — reports too.
        let controller = config.userContentController
        controller.removeScriptMessageHandler(forName: MediaSession.messageHandlerName, contentWorld: .defaultClient)
        controller.add(MediaSession.shared, contentWorld: .defaultClient, name: MediaSession.messageHandlerName)
        controller.addUserScript(
            WKUserScript(
                source: VideoPopOut.mediaObserverScript,
                injectionTime: .atDocumentEnd, forMainFrameOnly: false,
                in: .defaultClient))
    }
}

/// Owns the live WKWebViews. Not an ObservableObject on purpose: handing out a
/// view must not publish a change and re-enter SwiftUI's update cycle.
@MainActor
final class WebViewPool {
    /// How many tabs may hold a live web view at once. Beyond this the
    /// least-recently-used is unloaded.
    static let capacity = 6

    private var views: [UUID: ZenWebView] = [:]
    /// Most-recently-used last.
    private var usageOrder: [UUID] = []

    weak var state: BrowserState?
    /// Set by `RootView` when a vault is configured. Passing it here rather
    /// than threading it through `WebView` and every one of its call sites
    /// keeps the change to the browsing path down to the two lines in
    /// `webView(for:…)` that install the observer (#008AD).
    weak var vault: PasswordVaultService?
    /// Kept alive for as long as their web views are: `WKUserContentController`
    /// holds its message handlers weakly, so an observer that only the
    /// configuration referenced would be gone before the first submit.
    private var loginObservers: [UUID: LoginFormObserver] = [:]

    func existing(for tabID: UUID) -> ZenWebView? { views[tabID] }

    func isLoaded(_ tabID: UUID) -> Bool { views[tabID] != nil }

    /// Get or create the web view backing a tab, evicting as needed.
    /// Compiled Focus blocklist, set before Focus mode creates any tab.
    var focusBlocklist: WKContentRuleList?

    /// Sepia's page tint. New views get it as a user script; live ones are
    /// updated in place, because a settings toggle should change what is on
    /// screen rather than what the *next* page looks like.
    var sepiaTintsPages: Bool = false {
        didSet {
            guard sepiaTintsPages != oldValue else { return }
            let source = SepiaPageTint.script(enabled: sepiaTintsPages)
            for view in views.values {
                view.evaluateJavaScript(source, completionHandler: nil)
            }
        }
    }

    func webView(for tab: Tab, space: Space, desktop: Bool, ephemeral: Bool = false)
        -> ZenWebView
    {
        touch(tab.id)
        if let existing = views[tab.id] { return existing }

        let config = WebEngine.configuration(
            for: space, desktop: desktop, ephemeral: ephemeral,
            blocklist: ephemeral ? focusBlocklist : nil, sepiaTint: sepiaTintsPages)
        // Only when a vault is actually connected: with none, Zen injects
        // nothing into page content at all (#008AB).
        if let vault, vault.isConfigured {
            loginObservers[tab.id] = LoginFormObserver.install(on: config, vault: vault)
        }
        let view = ZenWebView(frame: .zero, configuration: config)
        view.tabID = tab.id
        view.customUserAgent = desktop ? WebEngine.desktopUserAgent : WebEngine.mobileUserAgent
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        // We drive the insets ourselves from the layout state; letting UIKit
        // also adjust them would double-count the status bar.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.scrollsToTop = true
        view.pendingScrollY = tab.scrollY
        view.onNavigationChange = { [weak self] changed in
            guard let id = changed.tabID else { return }
            self?.state?.updateNavigation(id, changed.navigationState)
        }
        views[tab.id] = view
        state?.markLoaded(tab.id, true)
        evictIfNeeded()
        return view
    }

    /// Drop a tab's web view, keeping its metadata. The caller is responsible
    /// for having stashed the scroll offset first.
    func unload(_ tabID: UUID) {
        guard let view = views.removeValue(forKey: tabID) else { return }
        // A view that goes away mid-playback never gets to say it stopped, and
        // an unreleased claim would hold the audio session open for a page
        // that no longer exists (#008B0).
        MediaSession.shared.pageWentAway(MediaSession.pageIdentity(for: view))
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.onNavigationChange = nil
        view.removeFromSuperview()
        // The observer outlives nothing: its web view is going, and holding it
        // would leak one per unloaded tab.
        view.configuration.userContentController.removeScriptMessageHandler(
            forName: LoginFormFill.submitMessageHandler)
        loginObservers[tabID] = nil
        usageOrder.removeAll { $0 == tabID }
        state?.markLoaded(tabID, false)
    }

    func unloadAll() {
        for id in views.keys { unload(id) }
    }

    private func touch(_ tabID: UUID) {
        usageOrder.removeAll { $0 == tabID }
        usageOrder.append(tabID)
    }

    /// Never evict what is on screen: the active tab, a split partner, or an
    /// open glance.
    private func evictIfNeeded() {
        guard views.count > Self.capacity, let state else { return }
        let protected = Set(
            [state.activeTabID, state.splitSecondaryTabID, state.glanceTabID].compactMap { $0 })
        for candidate in usageOrder where views.count > Self.capacity {
            guard !protected.contains(candidate) else { continue }
            // Persist the scroll position before the view goes away.
            if let view = views[candidate] {
                let offset = view.scrollView.contentOffset.y
                state.updateTab(candidate) { $0.scrollY = Double(offset) }
            }
            unload(candidate)
        }
    }
}

/// WKWebView subclass carrying the small amount of per-tab state the delegate
/// needs.
///
/// **Deliberately nothing else** (#008AB). An embedded web view is often given
/// a custom `inputAccessoryView`, or has `inputAssistantItem` emptied, to get
/// rid of WebKit's form bar. Do not: that bar is where iOS puts the Password
/// AutoFill key, so replacing it takes a browser's only route to a password
/// manager away. The header here used to claim "keyboard-accessory
/// suppression"; there never was any, and there must not be.
final class ZenWebView: WKWebView {
    var tabID: UUID?
    /// Applied once the first navigation finishes, for session restore.
    var pendingScrollY: Double = 0
    /// Set while the app is driving a navigation, to avoid feedback loops
    /// between the omnibox text and the delegate's URL updates.
    var isProgrammaticNavigation = false
    /// The last URL we asked WebKit to load, successful or not.
    ///
    /// Without this, a failed load retries forever: the model URL never
    /// matches `webView.url` (which still holds the last page that *did*
    /// load), so every SwiftUI update fires the request again — and each
    /// attempt clears the failure that would have been shown. That is the
    /// "nothing happens, forever" in #0089A.
    var lastRequestedURL: URL?

    /// The document's own background colour, as last read out of the page.
    /// Nil where the page paints nothing of its own.
    private var pageBackgroundColor: UIColor?

    /// Where the page runs under the top safe area its scroll view carries a
    /// top inset, so a site's own fixed header starts below the Dynamic Island
    /// rather than behind it (#008A9). The strip that inset opens up has to
    /// look like *the page*, not like a black slab — so it is painted in the
    /// page's own background colour, and left clear (showing the space
    /// gradient) where the page has none.
    func syncUnderPageBackground() {
        guard scrollView.contentInset.top > 0 else {
            scrollView.backgroundColor = .clear
            return
        }
        scrollView.backgroundColor = pageBackgroundColor ?? .clear
    }

    /// Ask the document what colour it is. `underPageBackgroundColor` is no
    /// help: it comes back clear while the web view is transparent, which it
    /// must be so a space's gradient shows before the first paint.
    ///
    /// Skipped outright where there is no inset to fill, which on a layout that
    /// frames the content is always — this costs a page nothing it does not use.
    func refreshPageBackgroundColor() {
        guard scrollView.contentInset.top > 0 else { return }
        evaluateJavaScript(Self.pageBackgroundScript) { [weak self] result, _ in
            guard let self else { return }
            let parsed = (result as? String).flatMap(CSSColor.parse)
            // A transparent page background is not "black" — it is "let the
            // gradient through", which is what clear does.
            self.pageBackgroundColor = (parsed?.isTransparent ?? true) ? nil : parsed?.uiColor
            self.syncUnderPageBackground()
        }
    }

    /// Put the page's most relevant video into Picture in Picture (#008B0).
    /// The choosing happens in the page — see `VideoPopOut` for why, and for
    /// which video wins.
    func popOutVideo(_ completion: @escaping (VideoPopOut.Result) -> Void) {
        evaluateJavaScript(VideoPopOut.popOutScript) { result, error in
            guard error == nil else {
                // A page that refuses to run scripts at all (a PDF, an error
                // page) has no video either, so say the same thing.
                completion(
                    VideoPopOut.Result(
                        status: .none, index: -1, id: "", playing: false, candidates: 0))
                return
            }
            completion(VideoPopOut.Result.parse(result))
        }
    }

    /// `<body>` first: that is where a styled page puts its colour. `<html>` is
    /// the fallback, and is what a page that colours the root uses.
    private static let pageBackgroundScript = """
        (function () {
          var root = document.documentElement;
          var body = document.body;
          function read(el) {
            if (!el) { return null; }
            var c = window.getComputedStyle(el).backgroundColor;
            if (!c) { return null; }
            if (c === 'transparent' || /,\\s*0\\s*\\)$/.test(c)) { return null; }
            return c;
          }
          return read(body) || read(root) || 'rgba(0, 0, 0, 0)';
        })()
        """
    /// Called whenever WebKit moves `estimatedProgress`, `isLoading`,
    /// `canGoBack` or `canGoForward`. The customisable bar can put back,
    /// forward, reload/stop and a progress indicator on screen for every pane
    /// (#00896), so these are observed once here rather than polled per view.
    var onNavigationChange: ((ZenWebView) -> Void)?

    private var observations: [NSKeyValueObservation] = []

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        observations = [
            observe(\.estimatedProgress) { view, _ in ZenWebView.notify(view) },
            observe(\.isLoading) { view, _ in ZenWebView.notify(view) },
            observe(\.canGoBack) { view, _ in ZenWebView.notify(view) },
            observe(\.canGoForward) { view, _ in ZenWebView.notify(view) },
        ]
    }

    /// KVO hands us a non-isolated callback, but WebKit only ever mutates these
    /// properties on the main thread — so asserting that is honest, where a
    /// hop to `DispatchQueue.main` would put the progress bar a frame behind
    /// the load it is describing.
    private nonisolated static func notify(_ view: ZenWebView) {
        MainActor.assumeIsolated { view.onNavigationChange?(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ZenWebView is only ever created in code")
    }

    var navigationState: TabNavigationState {
        TabNavigationState(
            canGoBack: canGoBack, canGoForward: canGoForward, isLoading: isLoading,
            progress: estimatedProgress)
    }
}
