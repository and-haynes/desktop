//  SessionStore.swift
//  Zen's session restore, as a single JSON document.
//
//  Upstream `ZenSessionStore.restoreInitialTabData` reattaches per-tab Zen state
//  (`zenWorkspace`, `zenEssential`, `zenPinnedId`, …) onto Firefox's own session
//  store. We have no host session store to ride on, so this snapshot *is* the
//  session: spaces, every tab with its tier and owning space, which tab is
//  active per space, and the preferences that change how the browser looks.

import Foundation

/// Preferences that belong to the session rather than to a space.
struct ZenSettings: Codable, Equatable, Sendable {
    var searchEngine: SearchEngine = .duckduckgo
    /// `zen.view.compact.enable-at-startup`
    var compactModeEnabled: Bool = false
    /// `zen.view.compact.hide-tabbar`
    var compactHidesSidebar: Bool = true
    /// `zen.view.compact.hide-toolbar`
    var compactHidesToolbar: Bool = true
    /// Request desktop sites by default.
    var preferDesktopSite: Bool = false
    /// Sidebar stays open beside the content on iPad.
    var sidebarPinnedOnPad: Bool = true
    /// Follow system / Light / Dark, as `zen.view.window.scheme`.
    var appearance: AppearanceMode = .system
    /// How long the chrome lingers once the page is still, in seconds. Each
    /// step of the compact bar's ladder — expanded to pill, pill to gone —
    /// waits this long, so there is one number rather than three (#008AF).
    /// Upstream's nearest equivalent is
    /// `zen.view.compact.toolbar-hide-after-hover.duration`.
    var compactHideDelay: Double = 3.0
    /// How much the phone talks back. Default Normal; see `Haptics`.
    var hapticLevel: HapticLevel = .normal
    /// Show the clock, signal and battery. Off by default: in a browser the
    /// page *is* the app, and 60pt of someone else's status is a tax on every
    /// screenful. The Dynamic Island is hardware and stays regardless.
    var showStatusBar: Bool = false
    /// Which edge the vertical tab sidebar lives on. Zen desktop lets it move
    /// to the right; this mirrors that choice.
    var sidebarEdge: SidebarEdge = .leading
    /// How much of the screen the page gets. Cycled from the overflow menu or
    /// Cmd-Shift-F; persisted alongside compact mode.
    var layout: BrowserLayout = .card
    /// Require Face ID / passcode to return to a Focus session after the app
    /// has been in the background.
    var focusRequiresBiometrics: Bool = false

    init() {}

    // Swift's synthesized Decodable does *not* fall back to a property's
    // default when a key is missing — it throws. That would mean every new
    // setting we add makes existing session files undecodable, and since
    // SessionStore.load() treats a decode failure as "no session", shipping one
    // would silently wipe everyone's tabs. Decode each key optionally instead,
    // so an older file just picks up the defaults for whatever it predates.
    private enum CodingKeys: String, CodingKey {
        case searchEngine, compactModeEnabled, compactHidesSidebar, compactHidesToolbar
        case preferDesktopSite, sidebarPinnedOnPad, appearance, compactHideDelay, hapticLevel
        case showStatusBar, sidebarEdge, layout, focusRequiresBiometrics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ZenSettings()
        searchEngine =
            try c.decodeIfPresent(SearchEngine.self, forKey: .searchEngine)
            ?? fallback.searchEngine
        compactModeEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .compactModeEnabled)
            ?? fallback.compactModeEnabled
        compactHidesSidebar =
            try c.decodeIfPresent(Bool.self, forKey: .compactHidesSidebar)
            ?? fallback.compactHidesSidebar
        compactHidesToolbar =
            try c.decodeIfPresent(Bool.self, forKey: .compactHidesToolbar)
            ?? fallback.compactHidesToolbar
        preferDesktopSite =
            try c.decodeIfPresent(Bool.self, forKey: .preferDesktopSite)
            ?? fallback.preferDesktopSite
        sidebarPinnedOnPad =
            try c.decodeIfPresent(Bool.self, forKey: .sidebarPinnedOnPad)
            ?? fallback.sidebarPinnedOnPad
        appearance =
            try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance)
            ?? fallback.appearance
        compactHideDelay =
            try c.decodeIfPresent(Double.self, forKey: .compactHideDelay)
            ?? fallback.compactHideDelay
        hapticLevel =
            try c.decodeIfPresent(HapticLevel.self, forKey: .hapticLevel) ?? fallback.hapticLevel
        showStatusBar =
            try c.decodeIfPresent(Bool.self, forKey: .showStatusBar) ?? fallback.showStatusBar
        sidebarEdge =
            try c.decodeIfPresent(SidebarEdge.self, forKey: .sidebarEdge) ?? fallback.sidebarEdge
        layout = try c.decodeIfPresent(BrowserLayout.self, forKey: .layout) ?? fallback.layout
        focusRequiresBiometrics =
            try c.decodeIfPresent(Bool.self, forKey: .focusRequiresBiometrics)
            ?? fallback.focusRequiresBiometrics
    }
}

/// The whole persisted browser state. `version` lets a future format change
/// migrate rather than silently dropping everyone's tabs.
struct SessionSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = SessionSnapshot.currentVersion
    var spaces: [Space] = []
    var tabs: [Tab] = []
    var activeSpaceID: UUID?
    /// Remembered selection per space, so switching back lands where you left.
    var activeTabIDBySpace: [String: UUID] = [:]
    var settings: ZenSettings = ZenSettings()
    var savedAt: Date = Date()

    init() {}

    init(
        spaces: [Space], tabs: [Tab], activeSpaceID: UUID?,
        activeTabIDBySpace: [UUID: UUID], settings: ZenSettings
    ) {
        self.spaces = spaces
        self.tabs = tabs
        self.activeSpaceID = activeSpaceID
        // JSON object keys must be strings; UUID keys would encode as an array
        // of alternating key/value, which is unreadable and fragile.
        self.activeTabIDBySpace = Dictionary(
            uniqueKeysWithValues: activeTabIDBySpace.map { ($0.key.uuidString, $0.value) })
        self.settings = settings
    }

    var activeTabIDs: [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        for (key, value) in activeTabIDBySpace {
            if let uuid = UUID(uuidString: key) { out[uuid] = value }
        }
        return out
    }

    /// Drop anything self-inconsistent rather than restoring a broken browser:
    /// tabs whose space no longer exists, active-tab pointers to dead tabs, an
    /// active space that was deleted.
    func sanitised() -> SessionSnapshot {
        var copy = self
        let spaceIDs = Set(spaces.map(\.id))
        copy.tabs = tabs.filter { tab in
            tab.kind.isGlobal || tab.spaceID.map(spaceIDs.contains) == true
        }
        let tabIDs = Set(copy.tabs.map(\.id))
        copy.activeTabIDBySpace = activeTabIDBySpace.filter { key, value in
            UUID(uuidString: key).map(spaceIDs.contains) == true && tabIDs.contains(value)
        }
        if let active = activeSpaceID, !spaceIDs.contains(active) {
            copy.activeSpaceID = spaces.first?.id
        }
        if copy.activeSpaceID == nil { copy.activeSpaceID = spaces.first?.id }
        return copy
    }
}

/// Reads and writes the session document, coalescing bursts of saves.
final class SessionStore {
    private let file: JSONFileStore<SessionSnapshot>
    private let queue = DispatchQueue(label: "app.zen.session", qos: .utility)
    private var pendingWorkItem: DispatchWorkItem?
    /// Kept alongside the work item so `flush()` can write the latest state
    /// directly. A cancelled DispatchWorkItem silently does nothing when you
    /// call `perform()`, so flushing cannot go through the work item itself.
    private var pendingSnapshot: SessionSnapshot?

    /// How long to wait before flushing. Typing in the omnibox or scrolling can
    /// dirty the session many times a second; there is no point writing each one.
    private let debounceInterval: TimeInterval

    init(file: JSONFileStore<SessionSnapshot>? = nil, debounceInterval: TimeInterval = 1.0) {
        self.file = file ?? JSONFileStore<SessionSnapshot>(name: "session.json")
        self.debounceInterval = debounceInterval
    }

    var fileURL: URL { file.url }

    func load() -> SessionSnapshot? {
        guard let snapshot = file.load() else { return nil }
        guard snapshot.version <= SessionSnapshot.currentVersion else {
            // Written by a newer build: refuse rather than mangle it.
            return nil
        }
        return snapshot.sanitised()
    }

    /// Write immediately — used on backgrounding and termination.
    @discardableResult
    func saveNow(_ snapshot: SessionSnapshot) -> Bool {
        cancelPending()
        return write(snapshot)
    }

    /// Coalesced write — used for routine state changes.
    func save(_ snapshot: SessionSnapshot) {
        pendingWorkItem?.cancel()
        pendingSnapshot = snapshot
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingSnapshot else { return }
            self.pendingSnapshot = nil
            self.pendingWorkItem = nil
            _ = self.write(pending)
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Write any coalesced state out now. Safe to call when nothing is pending.
    func flush() {
        guard let pending = pendingSnapshot else { return }
        cancelPending()
        _ = write(pending)
    }

    private func cancelPending() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingSnapshot = nil
    }

    @discardableResult
    private func write(_ snapshot: SessionSnapshot) -> Bool {
        var copy = snapshot.sanitised()
        copy.savedAt = Date()
        return file.save(copy)
    }
}
