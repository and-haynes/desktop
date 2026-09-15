//  ExtensionEngine.swift
//  The WebKit half: controllers, contexts, permissions, actions and popups.
//
//  One `WKWebExtensionController` per space.
//
//  That is the central decision and it costs something, so it is worth stating
//  plainly. A controller is bound to one `WKWebsiteDataStore`, and Zen gives
//  each space its own store precisely so that signing into an account in Work
//  does not sign you in in Personal (see `WebEngine`). An extension's own
//  storage, its cookies and its background page all live in that store — so a
//  single shared controller would be a hole straight through the isolation the
//  rest of the app is built on: `storage.local` written by an extension in
//  Work would be read by the same extension in Personal.
//
//  The cost is that an extension enabled in three spaces has three background
//  pages and three copies of its storage. For a content blocker that is
//  exactly right. For something that syncs state it is surprising, and the
//  Settings screen says so.
//
//  Focus mode gets no controller at all. Focus promises an ephemeral session
//  with nothing written down; an extension with `storage` and a background
//  page is the opposite of that, and "your extensions are off in Focus" is a
//  promise that can be kept.

import Foundation
import UIKit
import WebKit

@available(iOS 18.4, *)
@MainActor
final class ExtensionEngine: NSObject, WKWebExtensionControllerDelegate, ExtensionWindowResolving {

    private unowned let host: ExtensionHost
    private unowned let store: ExtensionStore
    weak var state: BrowserState?
    weak var pool: WebViewPool?

    /// Keyed by the space's `dataStoreID` — the same key the website data
    /// store uses, because that is what a controller is really bound to.
    private var controllers: [UUID: WKWebExtensionController] = [:]
    private var windows: [UUID: ExtensionWindowProxy] = [:]
    /// `dataStoreID` → extension identifier → context.
    private var contexts: [UUID: [String: WKWebExtensionContext]] = [:]
    /// One proxy per tab, for the lifetime of the tab: WebKit compares these
    /// by identity.
    private var tabProxies: [UUID: ExtensionTabProxy] = [:]

    /// What the last `syncTabs` saw, so the next one can report the difference.
    private var knownTabIDs: Set<UUID> = []
    private var lastActiveTabID: UUID?
    private var lastTabSnapshots: [UUID: TabSnapshot] = [:]

    /// The fields worth telling an extension have changed. Compared as a whole
    /// rather than observed individually, because `tabs.onUpdated` wants one
    /// event carrying everything that moved.
    private struct TabSnapshot: Equatable {
        var url: URL
        var title: String
        var isLoading: Bool
        var isPinned: Bool
    }

    init(host: ExtensionHost, store: ExtensionStore) {
        self.host = host
        self.store = store
        super.init()
    }

    // MARK: Controllers

    /// The controller a web view in this space should be configured with, or
    /// nil where extensions do not run.
    func controller(for space: Space, ephemeral: Bool) -> WKWebExtensionController? {
        guard !ephemeral else { return nil }
        guard let state, state.focusSpaceID != space.id else { return nil }
        if let existing = controllers[space.dataStoreID] { return existing }

        let configuration = WKWebExtensionController.Configuration(
            identifier: space.dataStoreID)
        configuration.defaultWebsiteDataStore = WebEngine.dataStore(for: space)
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = self
        controllers[space.dataStoreID] = controller

        let window = ExtensionWindowProxy(state: state)
        windows[space.dataStoreID] = window
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)

        // A space that is created, or first visited, after launch still has to
        // end up with everything that is installed and enabled.
        refresh(space: space)
        syncTabs()
        return controller
    }

    private func spaceID(forController controller: WKWebExtensionController) -> UUID? {
        controllers.first { $0.value === controller }?.key
    }

    private func space(forDataStoreID id: UUID) -> Space? {
        state?.spaces.first { $0.dataStoreID == id }
    }

    func windowProxy(for context: WKWebExtensionContext) -> ExtensionWindowProxy? {
        guard let controller = context.webExtensionController,
            let key = spaceID(forController: controller)
        else { return windows.values.first }
        return windows[key]
    }

    // MARK: Loading and unloading

    /// Bring every live controller in line with the installed list. Called when
    /// the store changes — an install, a removal, an enable, a permission edit.
    func refreshAll() {
        for (dataStoreID, _) in controllers {
            guard let space = space(forDataStoreID: dataStoreID) else { continue }
            refresh(space: space)
        }
        publishActions()
    }

    private func refresh(space: Space) {
        guard let controller = controllers[space.dataStoreID] else { return }
        let wanted = store.enabledExtensions
        var loaded = contexts[space.dataStoreID] ?? [:]

        // Unload anything that has gone or been switched off, first: an update
        // reinstalls under the same id, and loading a second context for one
        // identifier is an error rather than a replacement.
        for (identifier, context) in loaded
        where !wanted.contains(where: { $0.id == identifier }) {
            try? controller.unload(context)
            loaded[identifier] = nil
        }

        for record in wanted {
            if let context = loaded[record.id] {
                apply(record, to: context)
                continue
            }
            loaded[record.id] = nil
            load(record, into: controller, space: space)
        }
        contexts[space.dataStoreID] = loaded
    }

    /// Reading a package is asynchronous — WebKit parses the manifest, the
    /// locales and the icons off the main thread — so a load is a task, and the
    /// context is registered when it comes back.
    private func load(
        _ record: InstalledExtension, into controller: WKWebExtensionController, space: Space
    ) {
        let directory = store.directory(for: record.id)
        let dataStoreID = space.dataStoreID
        Task { [weak self] in
            do {
                let webExtension = try await WKWebExtension(resourceBaseURL: directory)
                guard let self else { return }
                let context = WKWebExtensionContext(for: webExtension)
                context.uniqueIdentifier = record.id
                self.apply(record, to: context)
                try controller.load(context)
                self.contexts[dataStoreID, default: [:]][record.id] = context
                self.syncTabs()
                self.publishActions()
                self.host.clearLoadError(record.id)
            } catch {
                // A package WebKit refuses — a persistent background page, an
                // unreadable manifest, a bad declarativeNetRequest ruleset — is
                // reported on the row rather than swallowed, because from the
                // outside it looks exactly like an extension doing nothing.
                self?.host.recordLoadError(
                    record.id, (error as NSError).localizedDescription)
            }
        }
    }

    /// Push the owner's decisions onto a context. Safe to call repeatedly: the
    /// permission dictionaries are declarative, so this is also how a change in
    /// Settings reaches a running extension.
    private func apply(_ record: InstalledExtension, to context: WKWebExtensionContext) {
        var granted: [WKWebExtension.Permission: Date] = [:]
        for permission in record.grantedPermissions {
            granted[WKWebExtension.Permission(rawValue: permission)] = .distantFuture
        }
        var denied: [WKWebExtension.Permission: Date] = [:]
        for permission in record.deniedPermissions {
            denied[WKWebExtension.Permission(rawValue: permission)] = .distantFuture
        }
        context.grantedPermissions = granted
        context.deniedPermissions = denied

        var grantedPatterns: [WKWebExtension.MatchPattern: Date] = [:]
        for pattern in record.grantedHostPatterns + allowedSitePatterns(record) {
            guard let parsed = Self.matchPattern(pattern) else { continue }
            grantedPatterns[parsed] = .distantFuture
        }
        var deniedPatterns: [WKWebExtension.MatchPattern: Date] = [:]
        for pattern in record.deniedHostPatterns + deniedSitePatterns(record) {
            guard let parsed = Self.matchPattern(pattern) else { continue }
            deniedPatterns[parsed] = .distantFuture
        }
        // A per-site *denial* has to win over a granted `<all_urls>`, and
        // WebKit resolves a URL present in both in favour of the denial — so
        // the two dictionaries can simply both be set.
        context.grantedPermissionMatchPatterns = grantedPatterns
        context.deniedPermissionMatchPatterns = deniedPatterns

        // Extensions are inspectable only in a debug build; on a release build
        // this is a hole into somebody's browsing.
        #if DEBUG
            context.isInspectable = true
            context.inspectionName = record.name
        #endif
    }

    private func allowedSitePatterns(_ record: InstalledExtension) -> [String] {
        record.siteAccess.filter { $0.value == .allow }
            .keys.map(InstalledExtension.pattern(forHost:))
    }

    private func deniedSitePatterns(_ record: InstalledExtension) -> [String] {
        record.siteAccess.filter { $0.value == .deny }
            .keys.map(InstalledExtension.pattern(forHost:))
    }

    static func matchPattern(_ string: String) -> WKWebExtension.MatchPattern? {
        if string == "<all_urls>" { return WKWebExtension.MatchPattern.allURLs() }
        return try? WKWebExtension.MatchPattern(string: string)
    }

    // MARK: Tabs

    /// Tell every controller what changed since last time.
    ///
    /// Driven from `RootView` rather than by observing `BrowserState` here: the
    /// model publishes on every keystroke in the URL bar, and an extension does
    /// not need to hear about those.
    func syncTabs() {
        guard let state else { return }
        let visible = Self.visibleTabs(in: state)
        let ids = Set(visible.map(\.id))

        for tab in visible where tabProxies[tab.id] == nil {
            tabProxies[tab.id] = ExtensionTabProxy(
                tabID: tab.id, state: state, pool: pool, resolver: self)
        }

        // Each space's window lists its own tabs; essentials are in all of
        // them, exactly as the sidebar shows them.
        for (dataStoreID, window) in windows {
            guard let space = space(forDataStoreID: dataStoreID) else { continue }
            let ordered =
                state.tabs(kind: .essential, spaceID: nil)
                + state.tabs(kind: .pinned, spaceID: space.id)
                + state.tabs(kind: .normal, spaceID: space.id)
            window.tabProxies = ordered.filter { ids.contains($0.id) }
                .compactMap { tabProxies[$0.id] }
        }

        let opened = ids.subtracting(knownTabIDs)
        let closed = knownTabIDs.subtracting(ids)
        for id in opened {
            guard let proxy = tabProxies[id] else { continue }
            forEachController { $0.didOpenTab(proxy) }
        }
        for id in closed {
            guard let proxy = tabProxies[id] else { continue }
            forEachController { $0.didCloseTab(proxy, windowIsClosing: false) }
            tabProxies[id] = nil
            lastTabSnapshots[id] = nil
        }
        knownTabIDs = ids

        // Changed properties, as one event each.
        for tab in visible {
            guard let proxy = tabProxies[tab.id] else { continue }
            let snapshot = TabSnapshot(
                url: tab.url, title: tab.displayTitle,
                isLoading: state.navigation(for: tab.id).isLoading,
                isPinned: tab.kind.resetsOnClose)
            defer { lastTabSnapshots[tab.id] = snapshot }
            guard let previous = lastTabSnapshots[tab.id], previous != snapshot else { continue }
            var changed: WKWebExtension.TabChangedProperties = []
            if previous.url != snapshot.url { changed.insert(.URL) }
            if previous.title != snapshot.title { changed.insert(.title) }
            if previous.isLoading != snapshot.isLoading { changed.insert(.loading) }
            if previous.isPinned != snapshot.isPinned { changed.insert(.pinned) }
            guard !changed.isEmpty else { continue }
            forEachController { $0.didChangeTabProperties(changed, for: proxy) }
        }

        if state.activeTabID != lastActiveTabID {
            let previous = lastActiveTabID.flatMap { tabProxies[$0] }
            if let active = state.activeTabID, let proxy = tabProxies[active] {
                forEachController { $0.didActivateTab(proxy, previousActiveTab: previous) }
            }
            lastActiveTabID = state.activeTabID
            publishActions()
        }
    }

    /// What an extension is allowed to see: everything in the sidebar, in any
    /// non-Focus space. A Glance card that has not been promoted is not in the
    /// sidebar and is not here either, and Focus tabs are excluded outright.
    static func visibleTabs(in state: BrowserState) -> [Tab] {
        state.tabs.filter { tab in
            guard !state.isGlanceOnly(tab.id) else { return false }
            guard let focus = state.focusSpaceID else { return true }
            return tab.spaceID != focus
        }
    }

    private func forEachController(_ body: (WKWebExtensionController) -> Void) {
        for controller in controllers.values { body(controller) }
    }

    // MARK: Actions

    /// The current toolbar state of every loaded extension, flattened for the
    /// bar and the More menu.
    func publishActions() {
        guard let state, let space = state.activeSpace,
            let loaded = contexts[space.dataStoreID]
        else {
            host.setActions([])
            return
        }
        let tab = state.activeTabID.flatMap { tabProxies[$0] }
        var result: [ExtensionActionState] = []
        for record in store.enabledExtensions {
            guard let context = loaded[record.id] else { continue }
            guard let action = context.action(for: tab) else { continue }
            let icon = action.icon(for: CGSize(width: 32, height: 32))
            result.append(
                ExtensionActionState(
                    id: record.id,
                    name: record.name,
                    label: action.label,
                    badgeText: action.badgeText,
                    hasUnreadBadge: action.hasUnreadBadgeText,
                    isEnabled: action.isEnabled,
                    presentsPopup: action.presentsPopup,
                    hasOptionsPage: context.optionsPageURL != nil,
                    iconPNG: icon?.pngData()))
        }
        host.setActions(result)
    }

    /// The bar button's tap. WebKit decides what happens: an action with a
    /// popup asks us to present it through the delegate, one without fires the
    /// extension's click event.
    func performAction(extensionID: String) {
        guard let state, let space = state.activeSpace,
            let context = contexts[space.dataStoreID]?[extensionID]
        else { return }
        let tab = state.activeTabID.flatMap { tabProxies[$0] }
        if let tab {
            // Without this, an action that asks for `activeTab` gets nothing:
            // the permission is granted *by* a user gesture, and tapping the
            // extension's own button is the canonical one.
            context.userGesturePerformed(in: tab)
        }
        context.performAction(for: tab)
        publishActions()
    }

    /// `runtime.openOptionsPage`'s manual equivalent, from the settings row.
    func openOptionsPage(extensionID: String) {
        guard let state, let space = state.activeSpace,
            let context = contexts[space.dataStoreID]?[extensionID],
            let url = context.optionsPageURL
        else { return }
        state.newTab(url: url)
    }

    /// Whether this extension is actually loaded in the space on screen.
    func isLoaded(_ extensionID: String) -> Bool {
        guard let space = state?.activeSpace else { return false }
        return contexts[space.dataStoreID]?[extensionID] != nil
    }

    /// Runtime errors WebKit reported after the load succeeded.
    func runtimeErrors(_ extensionID: String) -> [String] {
        guard let space = state?.activeSpace,
            let context = contexts[space.dataStoreID]?[extensionID]
        else { return [] }
        return context.errors.map { ($0 as NSError).localizedDescription }
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        guard let key = spaceID(forController: controller), let window = windows[key] else {
            return []
        }
        return [window]
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        spaceID(forController: controller).flatMap { windows[$0] }
    }

    /// `tabs.create`. The new tab lands in the space the extension is running
    /// in, not in whatever is on screen — an extension in Work must not open a
    /// tab in Personal.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let state, let key = spaceID(forController: controller),
            let space = space(forDataStoreID: key)
        else { return completionHandler(nil, nil) }

        let url = configuration.url ?? Tab.newTabURL
        guard
            let tab = state.newTab(
                url: url, in: space.id, select: configuration.shouldBeActive)
        else { return completionHandler(nil, nil) }
        if configuration.shouldBePinned { state.setKind(.pinned, for: tab.id) }
        syncTabs()
        completionHandler(tabProxies[tab.id], nil)
    }

    /// `runtime.openOptionsPage`. Opened as an ordinary tab, which is what
    /// Firefox for Android does and the only thing that makes sense on a phone.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let state, let url = extensionContext.optionsPageURL else {
            return completionHandler(nil)
        }
        state.newTab(url: url)
        syncTabs()
        completionHandler(nil)
    }

    /// Permission prompts are answered from what the owner already decided on
    /// the install sheet, never by putting a dialog over the page.
    ///
    /// A prompt arriving here means the extension asked for something at
    /// runtime — `permissions.request()`. Silently granting it would make the
    /// install sheet a lie, so anything not already granted is refused, and
    /// Settings is where it can be changed.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        guard let record = record(for: extensionContext) else {
            return completionHandler([], nil)
        }
        let allowed = Set(record.grantedPermissions.map(WKWebExtension.Permission.init(rawValue:)))
        completionHandler(permissions.intersection(allowed), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        guard let record = record(for: extensionContext) else {
            return completionHandler([], nil)
        }
        completionHandler(urls.filter { allows(record, url: $0) }, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        guard let record = record(for: extensionContext) else {
            return completionHandler([], nil)
        }
        let granted = Set(record.grantedHostPatterns.compactMap(Self.matchPattern))
        completionHandler(patterns.filter { granted.contains($0) }, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        publishActions()
    }

    /// The popup. WebKit builds the web view; we put it on screen.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let webView = action.popupWebView else {
            return completionHandler(
                NSError(
                    domain: WKWebExtensionContext.errorDomain,
                    code: WKWebExtensionContext.Error.unknown.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "This extension has no popup."]))
        }
        let identifier = context.uniqueIdentifier
        host.present(
            ExtensionPopupRequest(
                id: identifier,
                title: record(for: context)?.name ?? action.label,
                webView: webView,
                dismiss: { [weak action] in action?.closePopup() }))
        completionHandler(nil)
    }

    private func record(for context: WKWebExtensionContext) -> InstalledExtension? {
        store.record(id: context.uniqueIdentifier)
    }

    /// Does the owner's configuration let this extension see this URL? The
    /// per-site override wins over the patterns, in both directions.
    private func allows(_ record: InstalledExtension, url: URL) -> Bool {
        if let host = url.host?.lowercased(), let override = record.siteAccess[host] {
            return override == .allow
        }
        for pattern in record.deniedHostPatterns {
            if Self.matchPattern(pattern)?.matches(url) == true { return false }
        }
        for pattern in record.grantedHostPatterns {
            if Self.matchPattern(pattern)?.matches(url) == true { return true }
        }
        return false
    }
}
