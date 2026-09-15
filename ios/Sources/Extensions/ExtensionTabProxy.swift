//  ExtensionTabProxy.swift
//  `tabs.*` and `windows.*`, answered out of `BrowserState`.
//
//  WebKit does not know what a tab is. `WKWebExtensionTab` and
//  `WKWebExtensionWindow` are the two protocols an app implements to say so,
//  and everything an extension can learn or do about tabs — `tabs.query`,
//  `tabs.create`, `tabs.update`, `tabs.remove`, `tabs.onActivated` — is routed
//  through them. So these two classes are the entire tabs API, written out.
//
//  Two things are worth knowing about the shape:
//
//  **Identity has to be stable.** WebKit holds these objects and compares them
//  by pointer: `didOpenTab` and `didCloseTab` must be handed the *same*
//  instance, or an extension sees an endless stream of tabs opening and none
//  closing. `ExtensionEngine` keeps one proxy per tab id and hands out that.
//
//  **Zen has more kinds of tab than the API does.** An essential is a tab, a
//  pinned tab is a tab, and a Glance card is a tab that is deliberately not in
//  the sidebar. The mapping: essentials and pinned tabs report `pinned: true`,
//  which is the nearest true thing the API can express, and a Glance that has
//  not been promoted is left out of the window's tab list — an extension
//  enumerating tabs should see what the sidebar sees.

import Foundation
import UIKit
import WebKit

/// Which window a tab belongs to depends on which extension is asking: every
/// space has its own controller and therefore its own window, and an
/// *essential* tab is in all of them. So the proxy does not hold a window — it
/// asks the engine, per context.
@available(iOS 18.4, *)
@MainActor
protocol ExtensionWindowResolving: AnyObject {
    func windowProxy(for context: WKWebExtensionContext) -> ExtensionWindowProxy?
}

@available(iOS 18.4, *)
@MainActor
final class ExtensionTabProxy: NSObject, WKWebExtensionTab {
    let tabID: UUID
    private weak var state: BrowserState?
    private weak var pool: WebViewPool?
    private weak var resolver: (any ExtensionWindowResolving)?

    init(
        tabID: UUID, state: BrowserState, pool: WebViewPool?,
        resolver: (any ExtensionWindowResolving)?
    ) {
        self.tabID = tabID
        self.state = state
        self.pool = pool
        self.resolver = resolver
    }

    private var tab: Tab? { state?.tab(id: tabID) }
    private var webView: ZenWebView? { pool?.existing(for: tabID) }

    // MARK: Placement

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        resolver?.windowProxy(for: context)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        resolver?.windowProxy(for: context)?.orderedTabIDs.firstIndex(of: tabID) ?? 0
    }

    // MARK: What the tab is

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func title(for context: WKWebExtensionContext) -> String? { tab?.displayTitle }

    func url(for context: WKWebExtensionContext) -> URL? {
        guard let tab else { return nil }
        // `zen://newtab` is our own sentinel for the start page, not a page an
        // extension could do anything with — `about:blank` is the honest
        // WebExtension-side equivalent and is what Safari reports for its own.
        return tab.isNewTabPage ? URL(string: "about:blank") : tab.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard let view = webView, view.isLoading else { return nil }
        return view.lastRequestedURL
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        guard let state else { return true }
        return !state.navigation(for: tabID).isLoading
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        webView?.bounds.size ?? UIScreen.main.bounds.size
    }

    /// Essentials and pinned tabs are the two tiers that survive a close, which
    /// is exactly what "pinned" means to an extension.
    func isPinned(for context: WKWebExtensionContext) -> Bool {
        tab?.kind.resetsOnClose ?? false
    }

    func setPinned(
        _ pinned: Bool, for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let state, let tab else { return completionHandler(nil) }
        // Unpinning an essential demotes it to a normal tab in the space it
        // came from, which is what the sidebar's own control does.
        state.setKind(pinned ? .pinned : .normal, for: tab.id)
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        state?.activeTabID == tabID
    }

    func setSelected(
        _ selected: Bool, for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if selected { state?.select(tabID) }
        completionHandler(nil)
    }

    func activate(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        state?.select(tabID)
        completionHandler(nil)
    }

    // MARK: Audio
    //
    // Zen tracks playback per *page* rather than per tab (`MediaSession`), and
    // has no mute control at all. Answering "no" to both is the honest
    // position: an extension that mutes a tab and then reads the state back
    // would otherwise be told a lie.

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { false }

    func isMuted(for context: WKWebExtensionContext) -> Bool { false }

    // MARK: Navigation

    func loadURL(
        _ url: URL, for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let state else { return completionHandler(nil) }
        // Through the model, not `webView.load` — the URL bar, the session file
        // and the history all read the model, and a navigation that bypassed it
        // would leave the bar showing the previous page.
        state.updateTab(tabID) { tab in
            tab.url = url
            tab.title = ""
            tab.loadFailure = nil
        }
        completionHandler(nil)
    }

    func reload(
        fromOrigin: Bool, for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }
        completionHandler(nil)
    }

    func goBack(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        webView?.goBack()
        completionHandler(nil)
    }

    func goForward(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        webView?.goForward()
        completionHandler(nil)
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        state?.closeTab(tabID)
        completionHandler(nil)
    }

    // MARK: Permissions

    /// Zen asks at install time and again in Settings, so a click inside the
    /// page must not quietly widen what an extension may read.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        false
    }
}

/// The one window. iOS has one at a time (iPad multitasking gives a second
/// *scene*, which gets its own `RootView` and therefore its own everything),
/// so `windows.getAll` returns exactly this.
@available(iOS 18.4, *)
@MainActor
final class ExtensionWindowProxy: NSObject, WKWebExtensionWindow {
    private weak var state: BrowserState?
    /// Set by the engine whenever the model changes: the proxies for this
    /// window's tabs, in sidebar order.
    var tabProxies: [ExtensionTabProxy] = []

    init(state: BrowserState) {
        self.state = state
    }

    var orderedTabIDs: [UUID] { tabProxies.map(\.tabID) }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabProxies }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let active = state?.activeTabID else { return tabProxies.first }
        return tabProxies.first { $0.tabID == active } ?? tabProxies.first
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        // A phone window is always the screen. Reporting `.fullscreen` would
        // make an extension offer to "restore" it, which there is no way to do.
        .normal
    }

    /// Focus mode never gets an extension controller at all (see
    /// `ExtensionEngine.controller(for:)`), so any window an extension can see
    /// is a normal one.
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        UIScreen.main.bounds
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        UIScreen.main.bounds
    }

    func focus(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // Already focused, always: there is one window and it is on screen.
        completionHandler(nil)
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // An app cannot close itself on iOS, and `exit(0)` is a crash report.
        completionHandler(
            NSError(
                domain: WKWebExtensionContext.errorDomain,
                code: WKWebExtensionContext.Error.unknown.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey: "A browser window cannot be closed on iOS."
                ]))
    }
}
