//  PageZoom.swift
//  Page zoom — "text size" — as a value, a ladder of steps, and a per-site
//  memory (#008B7).
//
//  Safari's `AA` control is one of the few browser affordances people reach for
//  without being taught, and the reason is that it *sticks*: a site you always
//  find too small is too small once. So the model here is two numbers rather
//  than one — a global default, and an override per **registrable domain** —
//  and the lookup falls through from the second to the first.
//
//  `WKWebView.pageZoom` is what applies it. Not a CSS injection: a user script
//  that rewrites a page's typography is both fragile and, on this codebase,
//  forbidden — `AutoFillSuppressionTests` fails any injected script that so
//  much as mentions an input. `pageZoom` is WebKit's own knob, it survives
//  navigation within a view, and it costs no script at all.
//
//  ## Why the domain table is a short one
//
//  Two hosts belong to the same site when they share the label below the
//  public suffix: `en.wikipedia.org` and `wikipedia.org` are one site,
//  `foo.github.io` and `bar.github.io` are two. Doing that exactly means
//  shipping the Public Suffix List. The vault's `DomainMatching` carries a
//  large curated subset because *there* a too-loose match is a credential
//  offered to the wrong site. Here the worst case is that two sites under an
//  exotic ccTLD share a text size, so this file keeps its own small table and
//  stays self-contained — which is also what lets the feature land on a branch
//  that has no vault.

import Foundation

enum PageZoom {

    // MARK: The ladder

    /// The steps the buttons walk, as multipliers. 50 % to 300 %, bunched
    /// where the eye can tell one from the next — the gap from 100 % to 115 %
    /// is a real change, the gap from 250 % to 300 % barely reads.
    static let steps: [Double] = [
        0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0,
    ]

    /// 100 %. Not `steps.first` — the default is a *value*, and it happening
    /// to be on the ladder is a property worth keeping true by test.
    static let standard: Double = 1.0

    static var minimum: Double { steps.first ?? standard }
    static var maximum: Double { steps.last ?? standard }

    /// Into range. A hand-edited file, or a build from next month with a wider
    /// ladder, must not be able to hand WebKit a 40× page.
    static func clamp(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return standard }
        return min(max(zoom, minimum), maximum)
    }

    /// The next step up, or the top if there is none.
    ///
    /// "Strictly greater" rather than "index + 1" on purpose: a value restored
    /// from a file need not be on the ladder at all, and stepping from 1.07
    /// should land on 1.15 rather than snapping backwards to 1.0 first.
    static func larger(than zoom: Double) -> Double {
        let current = clamp(zoom)
        return steps.first { $0 > current + tolerance } ?? maximum
    }

    /// The next step down, or the floor.
    static func smaller(than zoom: Double) -> Double {
        let current = clamp(zoom)
        return steps.last { $0 < current - tolerance } ?? minimum
    }

    /// Floating point: 1.15 read back out of JSON is not always 1.15, and a
    /// comparison that does not allow for that makes the button that would
    /// step *past* a value step onto it instead.
    private static let tolerance = 0.0001

    static func isAtMaximum(_ zoom: Double) -> Bool { clamp(zoom) >= maximum - tolerance }
    static func isAtMinimum(_ zoom: Double) -> Bool { clamp(zoom) <= minimum + tolerance }

    /// "125 %" — the readout. Whole percent, because a page zoom of 112.5 %
    /// is not a thing anyone asked for.
    static func percentLabel(_ zoom: Double) -> String {
        "\(Int((clamp(zoom) * 100).rounded()))%"
    }

    // MARK: What counts as "this site"

    /// The key a zoom is remembered under, or nil where there is nothing worth
    /// remembering against — the new tab page, a `data:` URL, an error page.
    ///
    /// A bare IP address or a single-label homelab host (`pi-a`, `vault`) has
    /// no registrable domain, so it is its own key: grouping every
    /// `192.168.x.y` under one site would be exactly wrong.
    ///
    /// The matching itself is `SiteKey`'s — shared with `ReaderSite`
    /// (#008BC), which wants the same "is this the same site" answer for a
    /// different memory. Only the suffix list is our own.
    static func siteKey(for url: URL?) -> String? {
        SiteKey.of(url, suffixes: suffixes)
    }

    /// Multi-label suffixes, kept to the ones a person actually browses under.
    /// Deliberately much shorter than the vault's table — see the file comment.
    static let suffixes: Set<String> = SiteKey.commonSuffixes
}

// MARK: - The per-site memory

/// Zoom levels the owner has chosen, by site. A small JSON document of its
/// own rather than a corner of the session file: it is written on a gesture
/// people repeat (three taps to get a site readable), and the session snapshot
/// is big enough already.
@MainActor
final class PageZoomStore: ObservableObject {
    /// Site key → multiplier. Only sites with an explicit choice appear; a
    /// site that has never been zoomed has no entry and follows the global
    /// default, which is what makes changing that default do anything.
    @Published private(set) var zoomBySite: [String: Double] = [:]

    private let file: JSONFileStore<[String: Double]>

    init(file: JSONFileStore<[String: Double]>? = nil) {
        self.file = file ?? JSONFileStore<[String: Double]>(name: "page-zoom.json")
        zoomBySite = (self.file.load() ?? [:]).compactMapValues(PageZoom.clamp)
    }

    /// What this URL should be shown at, given the global default.
    func zoom(for url: URL?, default globalDefault: Double) -> Double {
        guard let key = PageZoom.siteKey(for: url), let stored = zoomBySite[key] else {
            return PageZoom.clamp(globalDefault)
        }
        return PageZoom.clamp(stored)
    }

    /// Whether this site has an opinion of its own — what tells the readout it
    /// is showing an override rather than the default.
    func hasOverride(for url: URL?) -> Bool {
        guard let key = PageZoom.siteKey(for: url) else { return false }
        return zoomBySite[key] != nil
    }

    /// Remember a level for this site. An explicit 100 % is still an opinion —
    /// it is how you say "this one site should ignore my larger default" — so
    /// it is stored rather than treated as a reset.
    func set(_ zoom: Double, for url: URL?) {
        guard let key = PageZoom.siteKey(for: url) else { return }
        zoomBySite[key] = PageZoom.clamp(zoom)
        persist()
    }

    /// Forget this site, so it follows the global default again.
    func reset(_ url: URL?) {
        guard let key = PageZoom.siteKey(for: url), zoomBySite[key] != nil else { return }
        zoomBySite.removeValue(forKey: key)
        persist()
    }

    func resetAll() {
        guard !zoomBySite.isEmpty else { return }
        zoomBySite.removeAll()
        persist()
    }

    private func persist() {
        file.save(zoomBySite)
    }
}
