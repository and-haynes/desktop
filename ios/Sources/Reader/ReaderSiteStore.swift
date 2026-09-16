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
//  This duplicates the same short table `PageZoom.siteKey` keeps on the
//  `experimental` branch (#008B7). Deliberately: that file is not on this
//  branch, and copying twenty lines is cheaper than a cross-branch dependency.
//  **When #008B7 lands on `ios`, fold the two into one `SiteKey` helper** — the
//  semantics are already identical, which is what makes that a rename.

import Foundation

enum ReaderSite {

    /// The key settings are remembered under, or nil where there is nothing
    /// worth remembering against — a `data:` URL, the new tab page, a reader
    /// document of our own.
    ///
    /// A bare IP or a single-label homelab host (`pi-a`, `vault`) is its own
    /// key: filing every `10.0.0.x` under one site would be exactly wrong.
    static func siteKey(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !trimmed.isEmpty else { return nil }
        return registrableDomain(ofHost: trimmed) ?? trimmed
    }

    /// One label below the public suffix for the suffixes in `suffixes`;
    /// otherwise the last two labels.
    static func registrableDomain(ofHost host: String) -> String? {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2, !isIPv4(labels) else { return nil }
        for length in stride(from: min(3, labels.count), through: 2, by: -1) {
            let candidate = labels.suffix(length).joined(separator: ".")
            guard suffixes.contains(candidate) else { continue }
            guard labels.count > length else { return nil }
            return labels.suffix(length + 1).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    private static func isIPv4(_ labels: [String]) -> Bool {
        labels.count == 4
            && labels.allSatisfy { label in
                guard let value = Int(label), label.count <= 3 else { return false }
                return (0...255).contains(value)
            }
    }

    /// Multi-label suffixes, kept to the ones a person actually reads under.
    static let suffixes: Set<String> = [
        "co.uk", "org.uk", "me.uk", "ac.uk", "gov.uk", "net.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
        "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
        "com.br", "com.cn", "com.mx", "com.tr", "com.ar", "com.tw", "com.sg",
        "co.in", "co.za", "co.kr", "co.il", "co.th", "com.hk",
        // Private suffixes that behave like public ones: two GitHub Pages blogs
        // are two different sites and should be remembered separately.
        "github.io", "gitlab.io", "pages.dev", "netlify.app", "vercel.app",
        "herokuapp.com", "web.app", "workers.dev", "fly.dev",
        "substack.com", "medium.com", "bearblog.dev",
        "duckdns.org", "ts.net",
    ]
}

// MARK: - The memory

/// Reader settings the owner has chosen, by site. Its own small JSON document
/// rather than a corner of the session file: it is written every time a slider
/// settles, and the session snapshot carries every tab in the browser.
@MainActor
final class ReaderSiteStore: ObservableObject {
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
