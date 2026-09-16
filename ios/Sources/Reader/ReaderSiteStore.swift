//  ReaderSiteStore.swift
//  Reader appearance, remembered per site (#008BC).
//
//  The point of a reader's controls is that you set them once. Setting them
//  once *globally* is not enough — a site whose own type is small, or whose
//  articles are code-heavy and want a mono face, is a standing exception — so
//  the lookup is two-level: a per-registrable-domain override falling back to
//  the global default in `ZenSettings.readerDefaults`.
//
//  ## What counts as "this site"
//
//  Two hosts are one site when they share the label below the public suffix:
//  `en.wikipedia.org` and `wikipedia.org` are one, `a.github.io` and
//  `b.github.io` are two. Exactness there means shipping the Public Suffix
//  List, which is not worth a megabyte for a font size — the worst case here
//  is two sites under an exotic ccTLD sharing a reader theme.
//
//  The matching is `SiteKey`'s, shared with `PageZoom` (#008B7) now that
//  both live on `ios` — this file used to carry its own twenty-line copy,
//  written before the two branches could see one another.

import Foundation

enum ReaderSite {

    /// The key settings are remembered under, or nil where there is nothing
    /// worth remembering against — a `data:` URL, the new tab page, a reader
    /// document of our own.
    ///
    /// A bare IP or a single-label homelab host (`pi-a`, `vault`) is its own
    /// key: filing every `10.0.0.x` under one site would be exactly wrong.
    ///
    /// The matching itself is `SiteKey`'s — shared with `PageZoom` (#008B7),
    /// which wants the same "is this the same site" answer for a different
    /// memory. Only the suffix list is our own: a reader cares about a
    /// couple of publishing platforms a zoom level never needs to.
    static func siteKey(for url: URL?) -> String? {
        SiteKey.of(url, suffixes: suffixes)
    }

    /// `SiteKey.commonSuffixes` plus the publishing platforms people actually
    /// read long-form articles on.
    static let suffixes: Set<String> = SiteKey.commonSuffixes.union([
        "substack.com", "medium.com", "bearblog.dev",
    ])
}

// MARK: - The memory

/// Reader settings the owner has chosen, by site. Its own small JSON document
/// rather than a corner of the session file: it is written every time a slider
/// settles, and the session snapshot carries every tab in the browser.
@MainActor
final class ReaderSiteStore: ObservableObject {
    /// One store, because there is one file. Two instances over the same
    /// document each hold their own idea of what is in it, and the later write
    /// wins — so "Forget every site" in Settings would come back the next time
    /// a slider moved in the reader.
    static let shared = ReaderSiteStore()

    /// Site key → settings. Only sites with an explicit choice appear; a site
    /// that has never been adjusted has no entry and follows the global
    /// default, which is what makes changing that default do anything at all.
    @Published private(set) var settingsBySite: [String: ReaderSettings] = [:]

    private let file: JSONFileStore<[String: ReaderSettings]>

    init(file: JSONFileStore<[String: ReaderSettings]>? = nil) {
        self.file = file ?? JSONFileStore<[String: ReaderSettings]>(name: "reader-sites.json")
        settingsBySite = (self.file.load() ?? [:]).mapValues { $0.clamped() }
    }

    /// What this URL should be read at, given the global default.
    func settings(for url: URL?, default globalDefault: ReaderSettings) -> ReaderSettings {
        guard let key = ReaderSite.siteKey(for: url), let stored = settingsBySite[key] else {
            return globalDefault.clamped()
        }
        return stored.clamped()
    }

    /// Whether this site has an opinion of its own — what lets the panel offer
    /// "Use my defaults" only when there is something to undo.
    func hasOverride(for url: URL?) -> Bool {
        guard let key = ReaderSite.siteKey(for: url) else { return false }
        return settingsBySite[key] != nil
    }

    /// Remember a configuration for this site. Settings identical to the global
    /// default are still stored: choosing them explicitly is how you say "this
    /// site should ignore whatever I change my defaults to later".
    func set(_ settings: ReaderSettings, for url: URL?) {
        guard let key = ReaderSite.siteKey(for: url) else { return }
        let clamped = settings.clamped()
        guard settingsBySite[key] != clamped else { return }
        settingsBySite[key] = clamped
        persist()
    }

    /// Forget this site, so it follows the global default again.
    func reset(_ url: URL?) {
        guard let key = ReaderSite.siteKey(for: url), settingsBySite[key] != nil else { return }
        settingsBySite.removeValue(forKey: key)
        persist()
    }

    func resetAll() {
        guard !settingsBySite.isEmpty else { return }
        settingsBySite.removeAll()
        persist()
    }

    private func persist() {
        file.save(settingsBySite)
    }
}
