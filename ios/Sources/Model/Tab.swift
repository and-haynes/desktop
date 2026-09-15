//  Tab.swift
//  Zen's three tiers of tab, and the "unloaded" lifecycle.
//
//  Upstream (ZenPinnedTabManager) a tab is one of:
//    · essential — a global app tab, shown as a tile grid at the top of the
//      sidebar and visible from every space;
//    · pinned    — the same idea but scoped to one space, shown as rows above
//      the separator;
//    · normal    — an ordinary tab below the separator.
//
//  The important behavioural difference is what "close" means. Closing a normal
//  tab destroys it. Closing a pinned or essential tab does *not* — it resets the
//  tab to the URL it was pinned at and unloads it, because the point of a pinned
//  tab is that it is always there.

import Foundation
import CoreGraphics

enum TabKind: String, Codable, CaseIterable, Sendable {
    case essential
    case pinned
    case normal

    /// Essentials are shared across every space; the other two belong to one.
    var isGlobal: Bool { self == .essential }
    /// Pinned and essential tabs survive a "close" by resetting instead.
    var resetsOnClose: Bool { self != .normal }
}

struct Tab: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var url: URL
    var title: String = ""
    var kind: TabKind = .normal
    /// nil for essentials, which are not owned by any one space.
    var spaceID: UUID?
    /// The URL a pinned/essential tab resets to when closed. Set at pin time.
    var pinnedURL: URL?
    /// Best-effort scroll restore (`scrollY` in CSS pixels).
    var scrollY: Double = 0
    /// Last known favicon, persisted so a restored-but-unloaded tab still has
    /// its icon in the sidebar.
    var faviconData: Data?
    /// Whether a live WKWebView is currently backing this tab. Runtime-only:
    /// everything is unloaded at launch and reloads on first selection.
    var isLoaded: Bool = false
    /// Why the last load failed, if it did. Runtime-only — a failure is about
    /// this attempt, not something to restore a week later.
    var loadFailure: LoadFailure?

    private enum CodingKeys: String, CodingKey {
        case id, url, title, kind, spaceID, pinnedURL, scrollY, faviconData
    }

    init(
        url: URL, title: String = "", kind: TabKind = .normal, spaceID: UUID? = nil,
        pinnedURL: URL? = nil
    ) {
        self.url = url
        self.title = title
        self.kind = kind
        self.spaceID = spaceID
        self.pinnedURL = pinnedURL
    }

    /// A label for the sidebar: the page title if we have one, else the host.
    var displayTitle: String {
        if !title.isEmpty { return title }
        let host = URLDetector.prettyHost(url)
        return host.isEmpty ? url.absoluteString : host
    }

    /// Essentials show only an icon, so they need a one- or two-letter fallback
    /// when the favicon has not loaded yet.
    var monogram: String {
        let host = URLDetector.prettyHost(url)
        let source = host.isEmpty ? displayTitle : host
        return String(source.prefix(1)).uppercased()
    }

    var isNewTabPage: Bool { url == Tab.newTabURL }

    /// Zen's empty tab. `about:blank` renders as a white slab that fights the
    /// space gradient, so we use our own sentinel and draw a start page instead.
    static let newTabURL = URL(string: "zen://newtab")!

    static func newTab(in spaceID: UUID?) -> Tab {
        Tab(url: newTabURL, title: "New Tab", kind: .normal, spaceID: spaceID)
    }
}
