//  DomainMatching.swift
//  Deciding whether a stored login belongs to the page you are looking at
//  (#008AD).
//
//  This is the part of a password manager that is quietly security-critical.
//  Match too loosely and Zen offers your bank login on a page that merely has
//  "bank" in its host; match too tightly and the feature is useless, because
//  nobody stores `https://accounts.google.com/signin/v2/identifier` — they
//  store `google.com`.
//
//  The rule everyone converged on is the **registrable domain**: one label
//  below the public suffix. `mail.google.com` and `accounts.google.com` share
//  `google.com` and match each other; `google.com` and `google.co.uk` do not,
//  because `co.uk` is a public suffix and each registration under it is a
//  separate owner.
//
//  ## The public suffix list, and what is honestly here
//
//  Doing this exactly means shipping the Public Suffix List — some 6 000 rules
//  that change monthly. This ships a curated subset instead: the ICANN
//  multi-label suffixes people actually have logins under, plus the homelab's
//  own. That is a real limitation with a real consequence, so it is named
//  rather than buried: for a suffix not in the table, the registrable domain
//  falls back to the last two labels. For `example.museum` that is right; for
//  a login stored under an exotic three-label ccTLD it is too permissive by
//  one label — it could group two different registrations under one owner.
//
//  It is never too permissive across a *different* site, because the last two
//  labels always differ there. `DomainMatchingTests` pins the cases both ways.

import Foundation

enum DomainMatching {

    // MARK: Public suffixes

    /// Multi-label public suffixes, as a set of the suffix itself.
    ///
    /// Curated, not exhaustive — see the file comment. Ordered by how likely a
    /// homelab or a person is to have a login under it rather than
    /// alphabetically, because the lookup is a set and the order is for
    /// whoever reads it next.
    static let multiLabelSuffixes: Set<String> = [
        // The ones with real login traffic behind them.
        "co.uk", "org.uk", "me.uk", "ac.uk", "gov.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au", "asn.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz", "school.nz",
        "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp", "lg.jp",
        "com.br", "net.br", "org.br", "gov.br", "edu.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "co.in", "net.in", "org.in", "gen.in", "firm.in", "ind.in",
        "com.mx", "org.mx", "gob.mx", "edu.mx",
        "co.za", "org.za", "net.za", "gov.za", "ac.za",
        "com.sg", "net.sg", "org.sg", "edu.sg", "gov.sg",
        "com.hk", "net.hk", "org.hk", "edu.hk", "gov.hk",
        "co.kr", "or.kr", "ne.kr", "go.kr", "re.kr", "ac.kr",
        "com.tr", "net.tr", "org.tr", "gov.tr", "edu.tr",
        "com.ar", "net.ar", "org.ar", "gob.ar", "edu.ar",
        "co.il", "org.il", "net.il", "ac.il", "gov.il",
        "com.tw", "net.tw", "org.tw", "edu.tw", "gov.tw",
        "co.th", "in.th", "ac.th", "go.th", "or.th",
        "com.ua", "net.ua", "org.ua", "gov.ua", "edu.ua",
        "com.pl", "net.pl", "org.pl", "gov.pl", "edu.pl",
        "com.es", "org.es", "nom.es", "gob.es", "edu.es",
        "com.pt", "org.pt", "edu.pt", "gov.pt",
        "com.ru", "net.ru", "org.ru", "edu.ru", "gov.ru",
        "co.id", "web.id", "or.id", "ac.id", "go.id",
        "com.ph", "net.ph", "org.ph", "edu.ph", "gov.ph",
        "com.my", "net.my", "org.my", "edu.my", "gov.my",
        "com.vn", "net.vn", "org.vn", "edu.vn", "gov.vn",
        // Private suffixes that behave like public ones for this purpose: two
        // GitHub Pages sites are two different owners.
        "github.io", "gitlab.io", "pages.dev", "workers.dev", "netlify.app",
        "vercel.app", "herokuapp.com", "azurewebsites.net", "cloudfront.net",
        "s3.amazonaws.com", "firebaseapp.com", "web.app", "onrender.com",
        "fly.dev", "ngrok.io", "ngrok-free.app", "trycloudflare.com",
        "duckdns.org", "tailscale.net", "ts.net",
    ]

    // MARK: Registrable domain

    /// The registrable domain of a host, lowercased — or nil when the host has
    /// no such thing.
    ///
    /// A bare IP address and `localhost` return nil deliberately: neither has
    /// an owner in the PSL sense, so they are matched exactly instead. Grouping
    /// every `192.168.x.y` under one "domain" would be precisely the
    /// too-permissive failure this file exists to avoid.
    static func registrableDomain(ofHost host: String) -> String? {
        let normalised = normaliseHost(host)
        guard !normalised.isEmpty else { return nil }
        guard !isIPAddress(normalised) else { return nil }

        let labels = normalised.split(separator: ".").map(String.init)
        // "localhost", "vault", "pi-a" — single-label hosts have no registrable
        // domain; the homelab is full of them and they match by host.
        guard labels.count >= 2 else { return nil }

        // Longest matching suffix wins, so `foo.co.uk` beats a hypothetical
        // `uk` rule. Only two- and three-label suffixes are in the table.
        //
        // The upper bound is `labels.count`, not `labels.count - 1`: a host
        // that *is* exactly a public suffix (`co.uk`, `github.io`) has to be
        // recognised as one so it can return nil. Bounding it one lower made
        // `co.uk` fall through to the two-label default and claim itself as a
        // registrable domain, which would have put every `*.co.uk` login in one
        // bucket.
        for suffixLength in stride(from: min(3, labels.count), through: 2, by: -1) {
            let candidate = labels.suffix(suffixLength).joined(separator: ".")
            if multiLabelSuffixes.contains(candidate) {
                guard labels.count > suffixLength else { return nil }
                return labels.suffix(suffixLength + 1).joined(separator: ".")
            }
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// The registrable domain of a URL string, tolerant of what is actually
    /// stored in vaults: `example.com`, `example.com/login`, `*.example.com`,
    /// `https://example.com:8443/`.
    static func registrableDomain(ofURLString string: String) -> String? {
        guard let host = host(ofURLString: string) else { return nil }
        return registrableDomain(ofHost: host)
    }

    /// Pull a host out of the many shapes a vault URI comes in.
    static func host(ofURLString string: String) -> String? {
        var candidate = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        // `*.example.com` is a wildcard people type by hand; the star is not
        // part of the host.
        if candidate.hasPrefix("*.") { candidate = String(candidate.dropFirst(2)) }

        // A URI with no scheme parses as a *path*, not a host, so `URL` returns
        // nil for `host` on `example.com/login` — the single most common shape
        // in a vault. Give it a scheme first.
        if !candidate.contains("://") { candidate = "https://" + candidate }

        guard let url = URL(string: candidate), let host = url.host else {
            return nil
        }
        let normalised = normaliseHost(host)
        return normalised.isEmpty ? nil : normalised
    }

    /// Lowercase, strip a trailing dot (`example.com.` is the same name) and
    /// strip the brackets from an IPv6 literal.
    ///
    /// `www.` is deliberately *not* stripped: it is a real label, and dropping
    /// it here would make `www.example.com` and `example.com` compare equal as
    /// *hosts*, which is a stronger claim than the domain match already makes
    /// for them.
    static func normaliseHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value = String(value.dropLast()) }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return true }
        return false
    }

    // MARK: Matching

    /// How well a stored login matches the page — and it is an ordering, not a
    /// boolean, because the panel puts exact-host matches above
    /// same-domain ones. Higher is better.
    enum Quality: Int, Comparable, Sendable {
        case none = 0
        case domain = 1
        case host = 2
        case exact = 3

        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Does `storedURI` match `pageURL`, and how well?
    ///
    /// `match` is the vault's own instruction for the URI and is obeyed: a user
    /// who set an entry to `exact` because two services share a host means it.
    static func quality(of stored: VaultURI, against pageURL: URL) -> Quality {
        guard let pageHost = pageURL.host.map(normaliseHost), !pageHost.isEmpty else {
            return .none
        }
        let storedTrimmed = stored.uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !storedTrimmed.isEmpty else { return .none }

        switch stored.match {
        case .never:
            return .none

        case .exact:
            return storedTrimmed == pageURL.absoluteString ? .exact : .none

        case .startsWith:
            return pageURL.absoluteString.hasPrefix(storedTrimmed) ? .exact : .none

        case .regularExpression:
            // Anchored at both ends, like Bitwarden: an unanchored pattern
            // matching a substring of a URL is how "evil.com/?x=bank.com"
            // steals a login.
            guard
                let regex = try? NSRegularExpression(
                    pattern: "^(?:\(storedTrimmed))$", options: [.caseInsensitive])
            else { return .none }
            let subject = pageURL.absoluteString
            let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
            return regex.firstMatch(in: subject, options: [], range: range) != nil ? .exact : .none

        case .host:
            guard let storedHost = host(ofURLString: storedTrimmed) else { return .none }
            // Bitwarden's "host" includes the port; a vault entry for
            // `vault.lan:8443` should not fill on `vault.lan:9000`.
            let storedPort = port(ofURLString: storedTrimmed)
            let pagePort = pageURL.port
            guard storedHost == pageHost else { return .none }
            if let storedPort, let pagePort, storedPort != pagePort { return .none }
            return .host

        case .domain:
            guard let storedHost = host(ofURLString: storedTrimmed) else { return .none }
            if storedHost == pageHost { return .host }
            // No registrable domain (an IP, or `localhost`) means match the
            // host exactly or not at all — which the line above already did.
            guard
                let storedDomain = registrableDomain(ofHost: storedHost),
                let pageDomain = registrableDomain(ofHost: pageHost)
            else { return .none }
            return storedDomain == pageDomain ? .domain : .none
        }
    }

    /// The best quality any of a login's URIs achieves against the page.
    static func quality(of login: VaultLogin, against pageURL: URL) -> Quality {
        login.uris.reduce(Quality.none) { best, uri in
            max(best, quality(of: uri, against: pageURL))
        }
    }

    /// Logins that match the page, best first, then by title.
    ///
    /// Sorting matters more than it looks: the first row is the one someone
    /// taps without reading, so an exact-host match has to be above a
    /// same-domain one. Ties break on title so the order does not shuffle
    /// between syncs.
    static func matches(for pageURL: URL, in logins: [VaultLogin]) -> [VaultLogin] {
        logins
            .compactMap { login -> (VaultLogin, Quality)? in
                let quality = quality(of: login, against: pageURL)
                return quality == .none ? nil : (login, quality)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    private static func port(ofURLString string: String) -> Int? {
        var candidate = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("*.") { candidate = String(candidate.dropFirst(2)) }
        if !candidate.contains("://") { candidate = "https://" + candidate }
        return URL(string: candidate)?.port
    }
}
