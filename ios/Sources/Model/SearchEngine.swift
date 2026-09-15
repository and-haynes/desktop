//  SearchEngine.swift
//  Search providers and the URL-vs-search decision the omnibox makes.

import Foundation

enum SearchEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case duckduckgo
    case google
    case bing
    case startpage
    case ecosia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        case .startpage: return "Startpage"
        case .ecosia: return "Ecosia"
        }
    }

    /// SF Symbol shown in the omnibox chip.
    var symbol: String {
        switch self {
        case .duckduckgo: return "shield.lefthalf.filled"
        case .google: return "magnifyingglass"
        case .bing: return "b.circle"
        case .startpage: return "lock.shield"
        case .ecosia: return "leaf"
        }
    }

    var host: String {
        switch self {
        case .duckduckgo: return "duckduckgo.com"
        case .google: return "www.google.com"
        case .bing: return "www.bing.com"
        case .startpage: return "www.startpage.com"
        case .ecosia: return "www.ecosia.org"
        }
    }

    private var path: String {
        switch self {
        case .duckduckgo: return "/"
        case .google: return "/search"
        case .bing: return "/search"
        case .startpage: return "/sp/search"
        case .ecosia: return "/search"
        }
    }

    func searchURL(for query: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // URLComponents percent-encodes "+" as a literal plus, which servers read
        // as a space. Encode it explicitly so "c++" searches for what was typed.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? URL(string: "https://\(host)")!
    }

    /// Autocomplete endpoint. All five expose the OpenSearch JSON shape
    /// `["query", ["suggestion", ...]]`, except Startpage which has no public
    /// endpoint — it falls back to DuckDuckGo's.
    func suggestionsURL(for query: String) -> URL? {
        guard !query.isEmpty,
            let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        switch self {
        case .duckduckgo, .startpage:
            return URL(string: "https://duckduckgo.com/ac/?q=\(q)&type=list")
        case .google:
            return URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(q)")
        case .bing:
            return URL(string: "https://api.bing.com/osjson.aspx?query=\(q)")
        case .ecosia:
            return URL(string: "https://ac.ecosia.org/autocomplete?q=\(q)&type=list")
        }
    }
}

/// What the omnibox decided a typed string means.
enum OmniboxIntent: Equatable {
    /// Navigate straight to this URL.
    case navigate(URL)
    /// Run this as a search query.
    case search(String)
}

enum URLDetector {
    /// Schemes we will hand to WKWebView directly.
    private static let webSchemes: Set<String> = ["http", "https", "file", "about", "data"]

    /// Schemes that are real but that we deliberately do not treat as web
    /// navigation from the omnibox.
    private static let knownNonWebSchemes: Set<String> = ["javascript", "mailto", "tel", "sms"]

    /// A conservative TLD allowlist for bare hostnames. Without one, "swift ui"
    /// is a search but "notes.app" would be ambiguous — Zen's desktop urlbar
    /// leans on Firefox's fixup, which is far too large to port, so we take the
    /// common TLDs plus anything the user spells with an explicit scheme.
    private static let commonTLDs: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "co", "uk", "de", "fr", "eu",
        "edu", "gov", "mil", "int", "info", "biz", "me", "tv", "cc", "ai", "sh",
        "xyz", "site", "online", "tech", "ca", "au", "jp", "cn", "in", "br",
        "ru", "nl", "se", "no", "fi", "dk", "es", "it", "pl", "ch", "at", "be",
        "nz", "za", "mx", "kr", "local", "lan", "page", "blog", "cloud", "gg",
    ]

    /// A bare single-label name — no dot, no scheme, no port, no path, no
    /// whitespace. `meitner`, but not `meitner:8006` or `meitner/status`
    /// (already unambiguously hosts), nor `swift ui` (obviously a search).
    ///
    /// This is the one genuinely ambiguous input a URL bar takes: `meitner` is
    /// a machine on someone's network and `pottery` is a search, and nothing in
    /// the string tells them apart. Naming the case lets the omnibox offer both
    /// rather than guess.
    static func singleLabelName(_ rawInput: String) -> String? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 63 else { return nil }
        guard input.lowercased() != "localhost" else { return nil }
        guard input.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        guard !input.hasPrefix("-"), !input.hasSuffix("-") else { return nil }
        // A name that is only digits is a number, not a host.
        guard input.contains(where: { !$0.isNumber }) else { return nil }
        return input
    }

    /// Where a bare name would go. `http`, not `https`: a single-label name is
    /// by definition not a public host, and home-network services overwhelmingly
    /// answer on plain HTTP — the same reason `meitner:8006` already resolves
    /// this way.
    static func singleLabelURL(_ label: String) -> URL? {
        URL(string: "http://\(label)")
    }

    /// Decide whether `input` is a destination or a query, exactly as the
    /// omnibox does before it commits.
    ///
    /// `knownHosts` is the set of single-label hostnames the user has actually
    /// been to (see `BrowserState.knownSingleLabelHosts`). A bare word that
    /// matches one stops being ambiguous: you have been to `meitner`, so
    /// `meitner` means `meitner`.
    static func intent(
        for rawInput: String, engine: SearchEngine, knownHosts: Set<String> = []
    ) -> OmniboxIntent {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .search("") }

        // Anything with whitespace inside is a query, full stop. (A pasted URL
        // with a space in it is broken anyway.)
        if input.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return .search(input)
        }

        // Explicit scheme wins.
        if let schemeRange = input.range(of: "://") {
            let scheme = String(input[input.startIndex..<schemeRange.lowerBound]).lowercased()
            if webSchemes.contains(scheme), let url = URL(string: input), url.host != nil {
                return .navigate(url)
            }
            return .search(input)
        }
        if let colon = input.firstIndex(of: ":") {
            let scheme = String(input[input.startIndex..<colon]).lowercased()
            if knownNonWebSchemes.contains(scheme) { return .search(input) }
            // `about:blank`, `data:...` have no `//`.
            if webSchemes.contains(scheme), let url = URL(string: input) {
                return .navigate(url)
            }
        }

        // localhost, with or without a port or path.
        let hostCandidate = input.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
        let hostOnly = hostCandidate.split(separator: ":").first.map(String.init) ?? ""
        // A port, if one was given, must be a real port — "10.0.0.80:8006"
        // navigates, "ratio 3:2" does not.
        let portPart = hostCandidate.split(separator: ":").dropFirst().first.map(String.init)
        let portIsValid =
            portPart.map { part in
                if let value = Int(part) { return value > 0 && value <= 65535 }
                return false
            } ?? true
        guard portIsValid else { return .search(input) }
        if hostOnly.lowercased() == "localhost" {
            return URL(string: "http://\(input)").map(OmniboxIntent.navigate) ?? .search(input)
        }

        // Bare IPv4.
        let octets = hostOnly.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) {
            return URL(string: "http://\(input)").map(OmniboxIntent.navigate) ?? .search(input)
        }

        // A dotted hostname with a plausible TLD.
        let labels = hostOnly.split(separator: ".")
        if labels.count >= 2, let tld = labels.last.map({ String($0).lowercased() }),
            commonTLDs.contains(tld),
            labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } })
        {
            return URL(string: "https://\(input)").map(OmniboxIntent.navigate) ?? .search(input)
        }

        // A single-label name with a port or a path is a host: "meitner:8006"
        // and "meitner/" can only be a local machine. A *bare* single word is
        // deliberately still a search — "swift" and "meitner" are
        // indistinguishable, and turning every one-word search into a failed
        // navigation would be a far worse trade than the reverse. Typing a
        // scheme ("http://meitner") always navigates.
        if !hostOnly.isEmpty, !hostOnly.contains("."),
            hostOnly.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
            portPart != nil || input.contains("/")
        {
            return URL(string: "http://\(input)").map(OmniboxIntent.navigate) ?? .search(input)
        }

        // A bare word we have been to before is a machine, not a search term.
        if !knownHosts.isEmpty, let label = singleLabelName(input),
            knownHosts.contains(label.lowercased()), let url = singleLabelURL(label)
        {
            return .navigate(url)
        }

        return .search(input)
    }

    /// The URL to actually load for a typed string.
    static func resolve(_ input: String, engine: SearchEngine, knownHosts: Set<String> = []) -> URL
    {
        switch intent(for: input, engine: engine, knownHosts: knownHosts) {
        case .navigate(let url): return url
        case .search(let query): return engine.searchURL(for: query)
        }
    }

    /// Host without `www.`, for compact display in tab rows and the url pill.
    static func prettyHost(_ url: URL?) -> String {
        guard let host = url?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
