//  SiteKey.swift
//  What counts as "the same site" for a per-site memory (#008B7, #008BC).
//
//  Two features remember a choice per site — page zoom and reader appearance
//  — and both need the same answer to "is en.wikipedia.org the same site as
//  wikipedia.org, and is one.github.io the same site as two.github.io." They
//  used to carry their own twenty-line copy of this each, added six months
//  apart on branches that could not see one another. Now that both live on
//  `ios`, there is no reason for two copies of the same approximation — only
//  the suffix list differs, because a reader cares about a couple of
//  publishing platforms a zoom level never needs to.
//
//  Exactness would mean shipping the Public Suffix List, which is not worth
//  a megabyte for either feature — the worst case is two sites under an
//  exotic ccTLD sharing a zoom level or a reader theme.

import Foundation

enum SiteKey {

    /// The key a per-site choice is remembered under, or nil where there is
    /// nothing worth remembering against — the new tab page, a `data:` URL,
    /// an error page.
    ///
    /// A bare IP address or a single-label homelab host (`pi-a`, `vault`) has
    /// no registrable domain, so it is its own key: grouping every
    /// `192.168.x.y` under one site would be exactly wrong.
    static func of(_ url: URL?, suffixes: Set<String>) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !trimmed.isEmpty else { return nil }
        return registrableDomain(ofHost: trimmed, suffixes: suffixes) ?? trimmed
    }

    /// One label below the public suffix, for the suffixes given; otherwise
    /// the last two labels.
    static func registrableDomain(ofHost host: String, suffixes: Set<String>) -> String? {
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

    /// The suffixes `PageZoom` and `ReaderSite` both want: the multi-label
    /// public suffixes a person actually browses under, plus the private
    /// suffixes that behave like public ones (two GitHub Pages sites are two
    /// different sites).
    static let commonSuffixes: Set<String> = [
        "co.uk", "org.uk", "me.uk", "ac.uk", "gov.uk", "net.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
        "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
        "com.br", "com.cn", "com.mx", "com.tr", "com.ar", "com.tw", "com.sg",
        "co.in", "co.za", "co.kr", "co.il", "co.th", "com.hk",
        "github.io", "gitlab.io", "pages.dev", "netlify.app", "vercel.app",
        "herokuapp.com", "web.app", "workers.dev", "fly.dev",
        "duckdns.org", "ts.net",
    ]
}
