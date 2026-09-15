//  BrowserState.swift
//  The single source of truth: spaces, tabs, selection, and the model
//  operations the sidebar drives (move, pin, make-essential, close).
//
//  Tabs live in one flat ordered array. A "section" (essentials, this space's
//  pinned tabs, this space's normal tabs) is a filtered view of that array, so
//  reordering inside a section is a splice within the flat array and the
//  session snapshot stays a single list. This is the same shape upstream ends
//  up with — Zen keeps one tab strip per space and filters by
//  `zen-essential` / pinned state for display.

import Foundation
import SwiftUI
import Combine

@MainActor
final class BrowserState: ObservableObject {

    // MARK: Persisted model

    @Published private(set) var spaces: [Space] = []
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeSpaceID: UUID?
    @Published private(set) var activeTabIDBySpace: [UUID: UUID] = [:]
    @Published var settings = ZenSettings() {
        didSet {
            guard settings != oldValue else { return }
            // The haptics service is a singleton the views reach directly, so
            // the user's choice has to be pushed to it rather than read from
            // here.
            Haptics.shared.level = settings.hapticLevel
            scheduleSave()
        }
    }

    // MARK: Transient UI state

    /// Sidebar drawer (iPhone) / sidebar visibility (iPad).
    @Published var isSidebarVisible: Bool = false
    /// Which of compact mode's three bar states the chrome is in (#008AF).
    /// `RootView` owns the state machine; this is the copy the rest of the
    /// tree — the split panes, the page-tap gesture — reads. `expanded`
    /// whenever compact mode is off.
    @Published var compactBarPhase: CompactBarPhase = .expanded
    @Published var isOmniboxOpen: Bool = false
    @Published var omniboxText: String = ""
    /// Which tab the omnibox is editing. nil means the active tab — set
    /// explicitly when a split pane's own bar opens it, so typing a URL in the
    /// second pane does not navigate the first.
    @Published var omniboxTargetTabID: UUID?
    /// The tab a Glance card is showing over the current page, if any.
    @Published var glanceTabID: UUID?
    /// The second pane of a split, if split view is active.
    @Published var splitSecondaryTabID: UUID?
    /// 0...1 — the fraction of the width the primary pane gets.
    @Published var splitFraction: Double = 0.5
    /// A one-line transient message over the page (#008B0). Replaced rather
    /// than queued — the newest message describes what you just did.
    @Published var toast: ZenToastMessage?
    @Published var isHistorySheetPresented: Bool = false
    @Published var isSettingsPresented: Bool = false
    @Published var findInPageQuery: String = ""
    @Published var isFindBarVisible: Bool = false
    /// Live swipe offset in points while a space-switch gesture is in progress.
    @Published var spaceSwipeOffset: CGFloat = 0

    let history: HistoryStore
    let bookmarks: BookmarkStore
    let trustedCertificates: TrustedCertificateStore
    private let session: SessionStore

    /// The ephemeral Focus space, when Focus mode is on. Deliberately *not*
    /// persisted: it is in `spaces` so every sidebar and tab code path works
    /// unchanged, and filtered out again at snapshot time.
    @Published private(set) var focusSpaceID: UUID?
    /// Where to return when Focus is left.
    private var spaceBeforeFocus: UUID?
    /// Transient confirmation banner ("Your browsing history has been erased").
    @Published var focusToast: String?
    /// Focus content is covered until the owner re-authenticates.
    @Published var focusLocked: Bool = false

    /// A TLS challenge waiting on the owner. Exactly one at a time: a second
    /// one while a sheet is up is rejected rather than queued, because the page
    /// that raised it is already blocked and will retry.
    @Published var pendingCertificateChallenge: PendingCertificateChallenge?
    /// What the URL pill's security glyph opened, if anything.
    @Published var securityDetail: SecurityDetail?

    // MARK: Lifecycle

    init(
        session: SessionStore = SessionStore(),
        history: HistoryStore? = nil,
        bookmarks: BookmarkStore? = nil,
        trustedCertificates: TrustedCertificateStore? = nil,
        restore: Bool = true
    ) {
        self.session = session
        self.history = history ?? HistoryStore()
        self.bookmarks = bookmarks ?? BookmarkStore()
        self.trustedCertificates = trustedCertificates ?? TrustedCertificateStore()
        if restore, let snapshot = session.load(), !snapshot.spaces.isEmpty {
            apply(snapshot)
        } else {
            seedFirstRun()
        }
        // Seed the service from whatever was restored (or seeded) so the very
        // first gesture already obeys the setting.
        Haptics.shared.level = settings.hapticLevel
    }

    private func apply(_ snapshot: SessionSnapshot) {
        spaces = snapshot.spaces
        // Everything comes back unloaded; a tab only gets a WKWebView when it is
        // first selected (see WebViewPool).
        tabs = snapshot.tabs.map { tab in
            var t = tab
            t.isLoaded = false
            return t
        }
        activeSpaceID = snapshot.activeSpaceID ?? snapshot.spaces.first?.id
        activeTabIDBySpace = snapshot.activeTabIDs
        settings = snapshot.settings
    }

    private func seedFirstRun() {
        spaces = Space.starterSpaces()
        activeSpaceID = spaces.first?.id
        guard let first = spaces.first else { return }

        // A couple of essentials so the grid is not an empty mystery on launch.
        tabs = [
            Tab(
                url: URL(string: "https://zen-browser.app")!, title: "Zen Browser",
                kind: .essential, pinnedURL: URL(string: "https://zen-browser.app")!),
            Tab(
                url: URL(string: "https://duckduckgo.com")!, title: "DuckDuckGo",
                kind: .essential, pinnedURL: URL(string: "https://duckduckgo.com")!),
            Tab(
                url: URL(string: "https://news.ycombinator.com")!, title: "Hacker News",
                kind: .pinned, spaceID: first.id,
                pinnedURL: URL(string: "https://news.ycombinator.com")!),
            Tab(url: URL(string: "https://example.com")!, title: "Example Domain",
                kind: .normal, spaceID: first.id),
        ]
        activeTabIDBySpace[first.id] = tabs.last?.id
    }

    // MARK: Derived accessors

    /// Single-label hostnames the user has actually visited. A bare word in
    /// the omnibox that matches one navigates instead of searching.
    var knownSingleLabelHosts: Set<String> { history.singleLabelHosts }

    var isFocusMode: Bool { focusSpaceID != nil }

    /// True for tabs whose content must never touch disk.
    func isEphemeral(_ spaceID: UUID?) -> Bool {
        spaceID != nil && spaceID == focusSpaceID
    }

    var activeSpace: Space? {
        spaces.first { $0.id == activeSpaceID } ?? spaces.first
    }

    var activeSpaceIndex: Int {
        spaces.firstIndex { $0.id == activeSpaceID } ?? 0
    }

    var activeTab: Tab? {
        guard let spaceID = activeSpace?.id, let tabID = activeTabIDBySpace[spaceID] else {
            return nil
        }
        return tabs.first { $0.id == tabID }
    }

    var activeTabID: UUID? { activeTab?.id }

    /// Essentials are global; everything else belongs to one space.
    func tabs(kind: TabKind, spaceID: UUID?) -> [Tab] {
        tabs.filter { tab in
            guard tab.kind == kind else { return false }
            return kind.isGlobal ? true : tab.spaceID == spaceID
        }
    }

    var essentials: [Tab] { tabs(kind: .essential, spaceID: nil) }
    var pinnedTabs: [Tab] { tabs(kind: .pinned, spaceID: activeSpaceID) }
    var normalTabs: [Tab] { tabs(kind: .normal, spaceID: activeSpaceID) }

    func tab(id: UUID?) -> Tab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    /// The palette for the active space, with the appearance setting applied.
    /// An explicit Light or Dark overrides the space's own contrast heuristic.
    func palette(systemDark: Bool) -> ZenPalette {
        let base = settings.appearance.surfaceBase(
            systemDark: systemDark, spacePrefersDark: activeSpace?.theme.forcedDarkMode)
        guard let space = activeSpace else {
            return ZenPalette(accent: ZenTokens.defaultAccent, base: base)
        }
        return ZenPalette(accent: space.accent(isDark: base.isDark), base: base)
    }

    /// What SwiftUI should force for this session, or nil to follow the system.
    func preferredColorScheme(systemDark: Bool) -> ColorScheme? {
        if let explicit = settings.appearance.preferredColorScheme { return explicit }
        return activeSpace?.theme.forcedDarkMode.map { $0 ? .dark : .light }
    }

    // MARK: Selection

    func select(_ tabID: UUID) {
        guard let tab = tab(id: tabID) else { return }
        // Selecting an essential from another space keeps you where you are —
        // essentials are global, so they do not drag you across spaces.
        let spaceID = tab.kind.isGlobal ? activeSpaceID : tab.spaceID
        guard let spaceID else { return }
        if activeSpaceID != spaceID { activeSpaceID = spaceID }
        activeTabIDBySpace[spaceID] = tabID
        markLoaded(tabID)
        scheduleSave()
    }

    func markLoaded(_ tabID: UUID, _ loaded: Bool = true) {
        guard let index = index(of: tabID), tabs[index].isLoaded != loaded else { return }
        tabs[index].isLoaded = loaded
    }

    // MARK: Tab mutation

    @discardableResult
    func newTab(url: URL? = nil, in spaceID: UUID? = nil, select shouldSelect: Bool = true)
        -> Tab?
    {
        guard let space = spaceID ?? activeSpaceID else { return nil }
        var tab = Tab.newTab(in: space)
        if let url { tab.url = url; tab.title = "" }
        // New tabs land at the end of their space's normal section.
        let insertAt = lastIndex(ofKind: .normal, spaceID: space).map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: insertAt)
        if shouldSelect { select(tab.id) } else { scheduleSave() }
        return tab
    }

    func updateTab(_ tabID: UUID, _ mutate: (inout Tab) -> Void) {
        guard let index = index(of: tabID) else { return }
        var tab = tabs[index]
        mutate(&tab)
        guard tab != tabs[index] else { return }
        tabs[index] = tab
        scheduleSave()
    }

    /// Close a tab. Pinned and essential tabs are *reset*, not removed —
    /// upstream's `ZenPinnedTabManager` resets them to the URL they were pinned
    /// at and discards the content. Returns the tab that ended up selected.
    @discardableResult
    func closeTab(_ tabID: UUID) -> UUID? {
        guard let index = index(of: tabID) else { return activeTabID }
        let tab = tabs[index]

        if tab.kind.resetsOnClose {
            tabs[index].url = tab.pinnedURL ?? tab.url
            tabs[index].scrollY = 0
            tabs[index].isLoaded = false
            scheduleSave()
            return activeTabID
        }

        let spaceID = tab.spaceID
        let siblings = tabs(kind: .normal, spaceID: spaceID)
        let positionInSection = siblings.firstIndex { $0.id == tabID }

        tabs.remove(at: index)
        if glanceTabID == tabID { glanceTabID = nil }
        if splitSecondaryTabID == tabID { splitSecondaryTabID = nil }

        guard let spaceID, activeTabIDBySpace[spaceID] == tabID else {
            scheduleSave()
            return activeTabID
        }

        // Closing the selected tab selects its neighbour: the one that slid into
        // its place, else the one before it, else fall back to a pinned tab or
        // a fresh new tab so the space is never empty.
        let remaining = tabs(kind: .normal, spaceID: spaceID)
        var next: UUID?
        if let position = positionInSection, !remaining.isEmpty {
            next = remaining[min(position, remaining.count - 1)].id
        }
        if next == nil { next = tabs(kind: .pinned, spaceID: spaceID).last?.id }
        if let next {
            activeTabIDBySpace[spaceID] = next
            markLoaded(next)
            scheduleSave()
            return next
        }
        activeTabIDBySpace[spaceID] = nil
        return newTab(in: spaceID)?.id
    }

    /// Close every normal tab in the active space — Zen's "clear tabs" broom.
    func clearNormalTabs(in spaceID: UUID? = nil) {
        guard let space = spaceID ?? activeSpaceID else { return }
        let doomed = Set(tabs(kind: .normal, spaceID: space).map(\.id))
        guard !doomed.isEmpty else { return }
        tabs.removeAll { doomed.contains($0.id) }
        if let active = activeTabIDBySpace[space], doomed.contains(active) {
            activeTabIDBySpace[space] = tabs(kind: .pinned, spaceID: space).last?.id
        }
        if activeTabIDBySpace[space] == nil {
            newTab(in: space)
        } else {
            scheduleSave()
        }
    }

    /// Promote or demote a tab between the three tiers.
    func setKind(_ kind: TabKind, for tabID: UUID) {
        guard let index = index(of: tabID), tabs[index].kind != kind else { return }
        var tab = tabs.remove(at: index)
        let previousKind = tab.kind
        tab.kind = kind
        if kind.isGlobal {
            // Essentials belong to no space, but remember where they came from
            // so demoting puts them back somewhere sensible.
            tab.spaceID = tab.spaceID ?? activeSpaceID
        } else if tab.spaceID == nil {
            tab.spaceID = activeSpaceID
        }
        if kind.resetsOnClose {
            // Pin at the current URL, as upstream does.
            tab.pinnedURL = tab.url
        } else {
            tab.pinnedURL = nil
        }

        let destinationSpace = kind.isGlobal ? nil : tab.spaceID
        let insertAt = lastIndex(ofKind: kind, spaceID: destinationSpace).map { $0 + 1 }
            ?? defaultInsertIndex(for: kind)
        tabs.insert(tab, at: min(insertAt, tabs.count))

        // A tab that was selected stays selected through a tier change.
        if previousKind.isGlobal || kind.isGlobal, let spaceID = activeSpaceID {
            if activeTabIDBySpace[spaceID] == nil { activeTabIDBySpace[spaceID] = tab.id }
        }
        scheduleSave()
    }

    func togglePinned(_ tabID: UUID) {
        guard let tab = tab(id: tabID) else { return }
        setKind(tab.kind == .pinned ? .normal : .pinned, for: tabID)
    }

    func toggleEssential(_ tabID: UUID) {
        guard let tab = tab(id: tabID) else { return }
        setKind(tab.kind == .essential ? .normal : .essential, for: tabID)
    }

    /// Reorder within one section. `from`/`to` are offsets *inside that
    /// section*, matching what SwiftUI's `onMove` hands us.
    func moveTab(kind: TabKind, spaceID: UUID?, from source: IndexSet, to destination: Int) {
        var section = tabs(kind: kind, spaceID: kind.isGlobal ? nil : spaceID)
        guard !section.isEmpty else { return }
        section.move(fromOffsets: source, toOffset: destination)
        reorder(section: section, kind: kind, spaceID: spaceID)
    }

    /// Reorder by explicit ids — what the drag gesture on the essentials grid
    /// and the tab rows produce.
    func moveTab(_ tabID: UUID, toOffset offset: Int, kind: TabKind, spaceID: UUID?) {
        var section = tabs(kind: kind, spaceID: kind.isGlobal ? nil : spaceID)
        guard let current = section.firstIndex(where: { $0.id == tabID }) else { return }
        let clamped = min(max(offset, 0), section.count - 1)
        guard clamped != current else { return }
        let moved = section.remove(at: current)
        section.insert(moved, at: clamped)
        reorder(section: section, kind: kind, spaceID: spaceID)
    }

    /// Write a reordered section back into the flat array, leaving the slots
    /// occupied by other sections untouched.
    private func reorder(section: [Tab], kind: TabKind, spaceID: UUID?) {
        let slots = tabs.indices.filter { i in
            tabs[i].kind == kind && (kind.isGlobal || tabs[i].spaceID == spaceID)
        }
        guard slots.count == section.count else { return }
        for (slot, tab) in zip(slots, section) { tabs[slot] = tab }
        scheduleSave()
    }

    private func lastIndex(ofKind kind: TabKind, spaceID: UUID?) -> Int? {
        tabs.lastIndex { $0.kind == kind && (kind.isGlobal || $0.spaceID == spaceID) }
    }

    /// Where a section starts when it is currently empty — keeps the flat array
    /// grouped essentials → pinned → normal.
    private func defaultInsertIndex(for kind: TabKind) -> Int {
        switch kind {
        case .essential:
            return tabs.firstIndex { $0.kind != .essential } ?? tabs.count
        case .pinned:
            return tabs.firstIndex { $0.kind == .normal } ?? tabs.count
        case .normal:
            return tabs.count
        }
    }

    // MARK: Space mutation

    @discardableResult
    func addSpace(name: String, icon: String, isSymbol: Bool, theme: ZenTheme) -> Space {
        let space = Space(name: name, icon: icon, isSymbol: isSymbol, theme: theme)
        spaces.append(space)
        activeSpaceID = space.id
        newTab(in: space.id)
        return space
    }

    func updateSpace(_ spaceID: UUID, _ mutate: (inout Space) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        var space = spaces[index]
        mutate(&space)
        guard space != spaces[index] else { return }
        spaces[index] = space
        scheduleSave()
    }

    /// Removing a space takes its tabs with it; essentials survive because they
    /// belong to no space. The last space cannot be removed, and Focus is left
    /// via its own toggle so that the erase always runs.
    func removeSpace(_ spaceID: UUID) {
        guard spaceID != focusSpaceID else {
            exitFocusMode()
            return
        }
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == spaceID })
        else { return }
        tabs.removeAll { $0.spaceID == spaceID && !$0.kind.isGlobal }
        activeTabIDBySpace[spaceID] = nil
        spaces.remove(at: index)
        if activeSpaceID == spaceID {
            activeSpaceID = spaces[min(index, spaces.count - 1)].id
        }
        scheduleSave()
    }

    func moveSpace(from source: IndexSet, to destination: Int) {
        spaces.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    func switchSpace(to spaceID: UUID) {
        guard spaces.contains(where: { $0.id == spaceID }), spaceID != activeSpaceID else {
            return
        }
        activeSpaceID = spaceID
        if activeTabIDBySpace[spaceID] == nil {
            // An empty space opens on a fresh tab rather than a blank frame.
            if let first = tabs(kind: .normal, spaceID: spaceID).first
                ?? tabs(kind: .pinned, spaceID: spaceID).first
            {
                activeTabIDBySpace[spaceID] = first.id
            } else {
                newTab(in: spaceID)
            }
        }
        scheduleSave()
    }

    /// `changeWorkspaceShortcut(±1)` — the swipe gesture and ⌃⇧← / ⌃⇧→ both land
    /// here. Wraps around, as upstream's carousel does.
    func cycleSpace(by delta: Int) {
        guard spaces.count > 1 else { return }
        let count = spaces.count
        let next = ((activeSpaceIndex + delta) % count + count) % count
        switchSpace(to: spaces[next].id)
    }

    // MARK: Tab cycling (⌃Tab / ⌃⇧Tab)

    func cycleTab(by delta: Int) {
        guard let spaceID = activeSpaceID else { return }
        let ordered = tabs(kind: .essential, spaceID: nil)
            + tabs(kind: .pinned, spaceID: spaceID)
            + tabs(kind: .normal, spaceID: spaceID)
        guard ordered.count > 1 else { return }
        let current = ordered.firstIndex { $0.id == activeTabID } ?? 0
        let next = ((current + delta) % ordered.count + ordered.count) % ordered.count
        select(ordered[next].id)
    }

    // MARK: Glance & split

    /// Open a link in a Glance card over the current page.
    func openGlance(url: URL) {
        guard let spaceID = activeSpaceID else { return }
        var tab = Tab(url: url, kind: .normal, spaceID: spaceID)
        tab.title = URLDetector.prettyHost(url)
        // The glance tab lives in the array (so it gets a web view) but is only
        // promoted into the sidebar when it is expanded.
        tabs.append(tab)
        glanceTabID = tab.id
    }

    /// `fullyOpenGlance()` — the card becomes a real tab next to its parent.
    func expandGlance() {
        guard let glanceID = glanceTabID else { return }
        glanceTabID = nil
        select(glanceID)
    }

    func closeGlance() {
        guard let glanceID = glanceTabID else { return }
        glanceTabID = nil
        if let index = index(of: glanceID) { tabs.remove(at: index) }
    }

    /// True when a Glance tab exists but has not been promoted — such a tab must
    /// stay out of the sidebar.
    func isGlanceOnly(_ tabID: UUID) -> Bool { glanceTabID == tabID }

    var isSplitActive: Bool { splitSecondaryTabID != nil }

    /// The tab the omnibox will navigate — its explicit target if a pane's own
    /// bar opened it, otherwise whatever is active.
    var omniboxTargetTab: Tab? {
        if let id = omniboxTargetTabID { return tab(id: id) }
        return activeTab
    }

    /// Open the omnibox against a specific pane.
    func openOmnibox(for tabID: UUID?, prefill: String) {
        omniboxTargetTabID = tabID
        omniboxText = prefill
        isOmniboxOpen = true
    }

    /// Split the active tab against the next tab in the space, matching Zen's
    /// two-pane `vsep` default. Upstream supports up to four panes; see README.
    func toggleSplit() {
        if isSplitActive {
            splitSecondaryTabID = nil
            return
        }
        guard let spaceID = activeSpaceID, let activeID = activeTabID else { return }
        let candidates = (tabs(kind: .pinned, spaceID: spaceID)
            + tabs(kind: .normal, spaceID: spaceID)).filter { $0.id != activeID }
        guard let partner = candidates.last ?? newTab(in: spaceID, select: false) else { return }
        splitFraction = 0.5
        splitSecondaryTabID = partner.id
    }

    func split(with tabID: UUID) {
        guard tabID != activeTabID else { return }
        splitFraction = 0.5
        splitSecondaryTabID = tabID
    }

    // MARK: Focus mode

    /// Record a visit unless we are in Focus. Every navigation goes through
    /// here rather than calling the store directly, so there is exactly one
    /// place this rule can be got wrong.
    func recordVisit(url: URL, title: String, spaceID: UUID?) {
        guard !isEphemeral(spaceID) else { return }
        history.record(url: url, title: title)
    }

    /// Enter Focus: a fresh ephemeral space, switched to immediately.
    @discardableResult
    func enterFocusMode() -> Space? {
        guard !isFocusMode else { return activeSpace }
        spaceBeforeFocus = activeSpaceID
        let space = Space.focusSpace()
        focusSpaceID = space.id
        spaces.append(space)
        activeSpaceID = space.id
        newTab(in: space.id)
        return space
    }

    /// Erase everything in Focus and start over, without leaving the mode.
    /// The space keeps its identity but gets a new `dataStoreID`, so the next
    /// web view is backed by a brand-new ephemeral store.
    func eraseFocus(announce: Bool = true) {
        guard let focusID = focusSpaceID else { return }
        let doomed = Set(tabs.filter { $0.spaceID == focusID }.map(\.id))
        tabs.removeAll { doomed.contains($0.id) }
        activeTabIDBySpace[focusID] = nil
        if let glance = glanceTabID, doomed.contains(glance) { glanceTabID = nil }
        if let split = splitSecondaryTabID, doomed.contains(split) { splitSecondaryTabID = nil }

        if let index = spaces.firstIndex(where: { $0.id == focusID }) {
            spaces[index].dataStoreID = UUID()
        }
        NotificationCenter.default.post(
            name: .zenFocusErased, object: nil,
            userInfo: ["tabs": doomed.map(\.uuidString)])

        newTab(in: focusID)
        if announce { focusToast = "Your browsing history has been erased" }
    }

    /// Leaving Focus erases too — that is the whole contract.
    func exitFocusMode() {
        guard let focusID = focusSpaceID else { return }
        eraseFocus(announce: false)

        let doomed = Set(tabs.filter { $0.spaceID == focusID }.map(\.id))
        tabs.removeAll { doomed.contains($0.id) }
        NotificationCenter.default.post(
            name: .zenFocusErased, object: nil,
            userInfo: ["tabs": doomed.map(\.uuidString)])

        spaces.removeAll { $0.id == focusID }
        activeTabIDBySpace[focusID] = nil
        focusSpaceID = nil
        focusLocked = false

        let destination = spaceBeforeFocus.flatMap { id in
            spaces.contains(where: { $0.id == id }) ? id : nil
        }
        activeSpaceID = destination ?? spaces.first?.id
        spaceBeforeFocus = nil
        focusToast = "Your browsing history has been erased"
        scheduleSave()
    }

    func toggleFocusMode() {
        if isFocusMode { exitFocusMode() } else { enterFocusMode() }
    }

    // MARK: TLS challenges

    /// True while a sheet we own is on screen. SwiftUI silently drops a second
    /// `.sheet` presented from the same view while one is already up, so the
    /// certificate prompt has to wait its turn rather than disappear — see the
    /// gated binding in RootView.
    var isBlockingSheetPresented: Bool {
        isHistorySheetPresented || isSettingsPresented || securityDetail != nil
    }

    /// What the glyph at the left of a tab's URL pill is saying.
    func securityBadge(for tab: Tab?) -> SecurityBadge {
        guard let tab, !tab.isNewTabPage else { return .search }
        if let failure = tab.loadFailure { return .failed(failure) }
        let host = tab.url.host?.lowercased()
        if let host, pendingCertificateChallenge?.host.lowercased() == host { return .challenge }
        guard tab.url.scheme?.lowercased() == "https" else { return .insecure }
        if let host,
            let approved = trustedCertificates.certificates.first(where: { $0.host == host })
        {
            return .trusted(approved)
        }
        return .secure
    }

    /// The badge's tap. A waiting challenge is not a "detail" — it is a
    /// question the page is blocked on, so it goes back to the prompt.
    func openSecurityDetail(for tab: Tab?) {
        switch securityBadge(for: tab) {
        case .search, .secure:
            return
        case .challenge:
            // The challenge is still pending; the gated binding in RootView
            // brings the sheet back as soon as nothing else is covering it.
            securityDetail = nil
        case .trusted(let certificate):
            securityDetail = .trusted(certificate: certificate)
        case .insecure:
            securityDetail = .insecure(host: tab?.url.host ?? tab?.url.absoluteString ?? "")
        case .failed(let failure):
            securityDetail = .failed(failure)
        }
    }

    func presentCertificateChallenge(_ challenge: PendingCertificateChallenge) {
        guard pendingCertificateChallenge == nil else {
            // Never drop the handler — answer it rather than leaving the load
            // hanging forever behind an already-open sheet.
            challenge.resolve(.reject)
            return
        }
        pendingCertificateChallenge = challenge
    }

    func resolveCertificateChallenge(_ disposition: PendingCertificateChallenge.Disposition) {
        guard let challenge = pendingCertificateChallenge else { return }
        pendingCertificateChallenge = nil
        challenge.resolve(disposition)
    }

    // MARK: Persistence

    /// Replace the model wholesale — what a sync merge produces. Private to
    /// the model's own file set: everything else goes through the operations
    /// above, which keep the invariants.
    func setSpaces(_ newSpaces: [Space]) { spaces = newSpaces }
    func setTabs(_ newTabs: [Tab]) { tabs = newTabs }

    /// After a wholesale replacement, make the selection point at something
    /// that exists: the remembered tab if it survived, else the first tab in
    /// the space, else a fresh one.
    func repairSelection() {
        let spaceIDs = Set(spaces.map(\.id))
        let tabIDs = Set(tabs.map(\.id))
        activeTabIDBySpace = activeTabIDBySpace.filter {
            spaceIDs.contains($0.key) && tabIDs.contains($0.value)
        }
        if let active = activeSpaceID, !spaceIDs.contains(active) {
            activeSpaceID = spaces.first?.id
        }
        if activeSpaceID == nil { activeSpaceID = spaces.first?.id }
        guard let spaceID = activeSpaceID else { return }
        if activeTabIDBySpace[spaceID] == nil {
            if let first = tabs(kind: .normal, spaceID: spaceID).first
                ?? tabs(kind: .pinned, spaceID: spaceID).first
            {
                activeTabIDBySpace[spaceID] = first.id
            } else {
                newTab(in: spaceID)
            }
        }
    }

    /// Focus leaves no trace: its space, its tabs and its selection are all
    /// stripped before anything reaches disk.
    func snapshot() -> SessionSnapshot {
        guard let focusID = focusSpaceID else {
            return SessionSnapshot(
                spaces: spaces, tabs: tabs, activeSpaceID: activeSpaceID,
                activeTabIDBySpace: activeTabIDBySpace, settings: settings)
        }
        var persistedSelection = activeTabIDBySpace
        persistedSelection[focusID] = nil
        return SessionSnapshot(
            spaces: spaces.filter { $0.id != focusID },
            tabs: tabs.filter { $0.spaceID != focusID },
            // Never restore into Focus.
            activeSpaceID: activeSpaceID == focusID
                ? (spaceBeforeFocus ?? spaces.first { $0.id != focusID }?.id)
                : activeSpaceID,
            activeTabIDBySpace: persistedSelection, settings: settings)
    }

    func scheduleSave() {
        session.save(snapshot())
    }

    func saveNow() {
        session.saveNow(snapshot())
    }
}
