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
import WebKit

enum WebEngine {
    /// Cached so that two tabs in one space genuinely share a session.
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

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

    static func configuration(for space: Space, desktop: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore(for: space)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.defaultWebpagePreferences.preferredContentMode = desktop ? .desktop : .mobile
        config.applicationNameForUserAgent = "Zen/0.1"
        config.suppressesIncrementalRendering = false
        // Long-press link targets come from WKUIDelegate's
        // contextMenuConfigurationForElement, so no script injection is needed.
        return config
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

    func existing(for tabID: UUID) -> ZenWebView? { views[tabID] }

    func isLoaded(_ tabID: UUID) -> Bool { views[tabID] != nil }

    /// Get or create the web view backing a tab, evicting as needed.
    func webView(for tab: Tab, space: Space, desktop: Bool) -> ZenWebView {
        touch(tab.id)
        if let existing = views[tab.id] { return existing }

        let config = WebEngine.configuration(for: space, desktop: desktop)
        let view = ZenWebView(frame: .zero, configuration: config)
        view.tabID = tab.id
        view.customUserAgent = desktop ? WebEngine.desktopUserAgent : WebEngine.mobileUserAgent
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.pendingScrollY = tab.scrollY
        views[tab.id] = view
        state?.markLoaded(tab.id, true)
        evictIfNeeded()
        return view
    }

    /// Drop a tab's web view, keeping its metadata. The caller is responsible
    /// for having stashed the scroll offset first.
    func unload(_ tabID: UUID) {
        guard let view = views.removeValue(forKey: tabID) else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
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
/// needs, plus the keyboard-accessory suppression an embedded browser wants.
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

    /// The page runs to the top edge when the status bar is hidden, so the
    /// scroll view carries a top inset to keep the site's own header clear of
    /// the Dynamic Island. The strip that inset opens up must look like *the
    /// page*, not like the chrome — WebKit already knows what colour that is,
    /// so borrow it rather than guessing.
    func syncUnderPageBackground() {
        guard scrollView.contentInset.top > 0 else {
            scrollView.backgroundColor = .clear
            return
        }
        scrollView.backgroundColor = underPageBackgroundColor
    }
}
