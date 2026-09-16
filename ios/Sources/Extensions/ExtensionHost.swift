//  ExtensionHost.swift
//  The iOS-17-safe face of the extension runtime.
//
//  Zen's deployment target is iOS 17; `WKWebExtension` needs 18.4. A stored
//  property cannot be marked `@available`, so a view model that held a
//  `WKWebExtensionController` would drag the whole app's minimum up with it.
//
//  So the split is: `ExtensionEngine` holds every WebKit type and is gated,
//  this holds the engine as an untyped reference and publishes plain values.
//  Everything above — the bar, the More menu, the settings screens, the popup
//  sheet — talks to this and compiles unconditionally. On iOS 17 the engine is
//  never created, `actions` stays empty, and the screens say why.

import Combine
import Foundation
import SwiftUI
import WebKit

/// A popup WebKit has asked us to show. Carries the web view WebKit built —
/// the popup is the extension's own document, running in the extension's own
/// world, and is not something to rebuild.
struct ExtensionPopupRequest: Identifiable, Equatable {
    var id: String
    var title: String
    var webView: WKWebView
    /// Tells WebKit the popup went away, so the extension's `window.close()`
    /// contract and its next `presentsPopup` are both right.
    var dismiss: () -> Void

    static func == (lhs: ExtensionPopupRequest, rhs: ExtensionPopupRequest) -> Bool {
        lhs.id == rhs.id && lhs.webView === rhs.webView
    }
}

@MainActor
final class ExtensionHost: ObservableObject {
    /// The toolbar state of every loaded extension, newest values.
    @Published private(set) var actions: [ExtensionActionState] = []
    /// A popup waiting to be presented.
    @Published var popup: ExtensionPopupRequest?
    /// Extension id → why it would not load. Shown on the settings row.
    @Published private(set) var loadErrors: [String: String] = [:]

    let store: ExtensionStore

    /// The app's one runtime.
    ///
    /// A singleton for a specific, measured reason rather than for
    /// convenience: `WKWebViewConfiguration.webExtensionController` can only be
    /// set *before* a web view is built, and the first browsing web view is
    /// built during the first layout pass — which happens before `RootView`'s
    /// `onAppear` can hand anything to the pool. A tab whose view was made
    /// without a controller never gets one, so the extension appears installed
    /// and does nothing, which is precisely the failure mode this feature
    /// exists to avoid. `Haptics` and `MediaSession` are shared for the same
    /// class of reason.
    static let shared = ExtensionHost()

    /// Typed as `AnyObject` on purpose — see the file comment. Nothing outside
    /// `engine` ever touches it.
    private var engineStorage: AnyObject?

    /// The installed list lives on the store, but every view in the feature is
    /// bound to *this* — so a change to the store has to be re-announced here
    /// or Settings does not redraw after an install. Forwarding once beats
    /// giving every view two `@ObservedObject`s to keep in step.
    private var storeObservation: AnyCancellable?

    /// WebExtensions arrived in WebKit on iOS 18.4. Everything user-facing
    /// reads this rather than writing the version out again.
    static var isSupported: Bool {
        if #available(iOS 18.4, *) { return true }
        return false
    }

    static let requirementNote =
        "Browser extensions need iOS 18.4 or later — that is the release WebKit added "
        + "WKWebExtension in. Everything else in Zen works as it does now."

    init(store: ExtensionStore? = nil) {
        let store = store ?? ExtensionStore()
        self.store = store
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    @available(iOS 18.4, *)
    var engine: ExtensionEngine? { engineStorage as? ExtensionEngine }

    /// Built on first use rather than in `start`.
    ///
    /// The first caller is a web view being configured during the first layout
    /// pass, which is earlier than `RootView.onAppear`. An engine that waited
    /// for `start` would hand that view no controller, and a web view cannot be
    /// given one afterwards — the tab would be unable to run an extension for
    /// as long as it lived. `ExtensionRuntimeTests` pins this.
    @available(iOS 18.4, *)
    @discardableResult
    private func ensureEngine() -> ExtensionEngine {
        if let existing = engineStorage as? ExtensionEngine { return existing }
        let engine = ExtensionEngine(host: self, store: store)
        engineStorage = engine
        return engine
    }

    /// Introduce the runtime to the browser. Called once, from `RootView`.
    func start(state: BrowserState, pool: WebViewPool) {
        guard #available(iOS 18.4, *) else { return }
        ensureEngine().attach(state: state, pool: pool)
    }

    /// The controller a browsing web view in this space belongs to. Returns nil
    /// below 18.4 and in Focus — but *not* merely because `start` has not run
    /// yet; see `ensureEngine`.
    @available(iOS 18.4, *)
    func controller(for space: Space, ephemeral: Bool) -> WKWebExtensionController? {
        ensureEngine().controller(for: space, ephemeral: ephemeral)
    }

    // MARK: Driven from the view tree

    /// The model moved: tabs opened, closed, navigated or changed selection.
    func tabsChanged() {
        guard #available(iOS 18.4, *) else { return }
        engine?.syncTabs()
        engine?.publishActions()
    }

    /// The installed list changed: load, unload or re-permission as needed.
    func installedChanged() {
        guard #available(iOS 18.4, *) else { return }
        engine?.refreshAll()
    }

    func performAction(_ extensionID: String) {
        guard #available(iOS 18.4, *) else { return }
        engine?.performAction(extensionID: extensionID)
    }

    func openOptionsPage(_ extensionID: String) {
        guard #available(iOS 18.4, *) else { return }
        engine?.openOptionsPage(extensionID: extensionID)
    }

    /// Whether the package is loaded in the space on screen right now — which
    /// is different from "installed and enabled", because a load can fail.
    func isLoaded(_ extensionID: String) -> Bool {
        guard #available(iOS 18.4, *) else { return false }
        return engine?.isLoaded(extensionID) ?? false
    }

    func runtimeErrors(_ extensionID: String) -> [String] {
        guard #available(iOS 18.4, *) else { return [] }
        return engine?.runtimeErrors(extensionID) ?? []
    }

    // MARK: Called back by the engine

    func setActions(_ next: [ExtensionActionState]) {
        guard actions != next else { return }
        actions = next
    }

    func present(_ request: ExtensionPopupRequest) {
        popup = request
    }

    func dismissPopup() {
        popup?.dismiss()
        popup = nil
    }

    func recordLoadError(_ extensionID: String, _ message: String) {
        loadErrors[extensionID] = message
    }

    func clearLoadError(_ extensionID: String) {
        guard loadErrors[extensionID] != nil else { return }
        loadErrors[extensionID] = nil
    }

    // MARK: Convenience for the views

    /// Actions worth putting in a menu: loaded, enabled, and not disabled by
    /// the extension itself for this page.
    var menuActions: [ExtensionActionState] {
        actions.filter(\.isEnabled)
    }

    var hasAnythingInstalled: Bool { !store.extensions.isEmpty }
}
