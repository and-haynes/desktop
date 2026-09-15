//  AddonsSource.swift
//  Turning something somebody typed into an XPI we can download.
//
//  What gets pasted into the install field is an addons.mozilla.org *listing*
//  page — `https://addons.mozilla.org/en-GB/firefox/addon/ublock-origin-lite/`
//  — because that is what a search engine returns and what the Share sheet
//  hands over. The listing is an HTML page for a human; the file behind it is
//  at an opaque `/firefox/downloads/file/<id>/…xpi` URL that changes with every
//  release.
//
//  AMO publishes a read-only JSON API for exactly this, so the resolution is
//  one request against a documented endpoint rather than scraping a page that
//  is redesigned twice a year. `slug(from:)` and `downloadURL(fromAPI:)` are
//  split out as pure functions so the parsing is tested without the network.
//
//  A URL that already points straight at a `.xpi`, `.crx` or `.zip` is used as
//  it stands — pasting a direct link should not require us to understand where
//  it came from.

import Foundation

enum AddonsSource {

    enum ResolveError: LocalizedError, Equatable {
        case notAURL
        case notAddons(host: String)
        case noSlug
        case noFile(slug: String)
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .notAURL:
                return "That is not a web address."
            case .notAddons(let host):
                return
                    "\(host) is not addons.mozilla.org. Paste an addons.mozilla.org listing, or "
                    + "a direct link to an .xpi, .crx or .zip file."
            case .noSlug:
                return "That addons.mozilla.org address does not name an add-on."
            case .noFile(let slug):
                return "addons.mozilla.org has no downloadable file for \(slug)."
            case .httpStatus(let code):
                return "addons.mozilla.org answered \(code)."
            }
        }
    }

    /// What `resolve` produces: somewhere to download from, and the listing to
    /// remember so the extension can be updated later.
    struct Resolution: Equatable {
        var downloadURL: URL
        var source: InstalledExtension.Source
        /// AMO's own name for the add-on, when the API gave us one.
        var displayName: String?
        var version: String?
    }

    static let packageExtensions: Set<String> = ["xpi", "crx", "zip"]

    /// A URL that is already the package.
    static func isDirectPackage(_ url: URL) -> Bool {
        packageExtensions.contains(url.pathExtension.lowercased())
    }

    /// `https://addons.mozilla.org/en-GB/firefox/addon/dark-reader/` → `dark-reader`.
    ///
    /// The locale segment is optional and the app segment is `firefox` or
    /// `android`; rather than encode the whole grammar, take the segment after
    /// `addon`, which is where AMO has always put the slug.
    static func slug(from url: URL) -> String? {
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let index = segments.firstIndex(of: "addon"), index + 1 < segments.count else {
            return nil
        }
        let slug = segments[index + 1]
        return slug.isEmpty ? nil : slug
    }

    static func isAddonsHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "addons.mozilla.org" || host.hasSuffix(".addons.mozilla.org")
    }

    /// The JSON detail endpoint for a slug. `lang` fixes the locale so the
    /// name we show is not whatever AMO guesses from an absent header.
    static func apiURL(slug: String) -> URL? {
        var components = URLComponents(string: "https://addons.mozilla.org/api/v5/addons/addon/")
        // Through `path`, not string concatenation: a slug is user input, and
        // `URLComponents` is what percent-encodes it back out.
        components?.path += slug + "/"
        components?.queryItems = [
            URLQueryItem(name: "app", value: "firefox"),
            URLQueryItem(name: "lang", value: "en-US"),
        ]
        return components?.url
    }

    /// Pull the file URL out of an AMO detail response.
    ///
    /// v5 gives `current_version.file.url`; v4 gave `current_version.files[0].url`
    /// and some cached responses still do. Both are read, newest shape first.
    static func downloadURL(fromAPI data: Data) -> (url: URL, version: String?, name: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let name = localised(root["name"])
        guard let current = root["current_version"] as? [String: Any] else { return nil }
        let version = current["version"] as? String

        if let file = current["file"] as? [String: Any],
            let raw = file["url"] as? String, let url = URL(string: raw)
        {
            return (url, version, name)
        }
        if let files = current["files"] as? [[String: Any]] {
            for file in files {
                guard let raw = file["url"] as? String, let url = URL(string: raw) else { continue }
                return (url, version, name)
            }
        }
        return nil
    }

    /// AMO returns localised strings as `{"en-US": "…"}`, or as a bare string
    /// when `lang` was pinned.
    private static func localised(_ any: Any?) -> String? {
        if let value = any as? String { return value }
        guard let dict = any as? [String: Any] else { return nil }
        for key in ["en-US", "en-GB", "en"] {
            if let value = dict[key] as? String { return value }
        }
        return dict.values.compactMap { $0 as? String }.first
    }

    /// Resolve what was typed into something downloadable.
    ///
    /// `fetch` is injected so the test suite resolves against a canned AMO
    /// response instead of the network.
    static func resolve(
        input: String,
        fetch: (URL) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(from: $0) }
    ) async throws -> Resolution {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = trimmed
        if !candidate.lowercased().hasPrefix("http") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate), url.host != nil else { throw ResolveError.notAURL }

        if isDirectPackage(url) {
            return Resolution(
                downloadURL: url,
                source: .file(name: url.lastPathComponent),
                displayName: nil, version: nil)
        }
        guard isAddonsHost(url) else {
            throw ResolveError.notAddons(host: url.host ?? candidate)
        }
        guard let slug = slug(from: url) else { throw ResolveError.noSlug }
        guard let api = apiURL(slug: slug) else { throw ResolveError.noSlug }

        let (data, response) = try await fetch(api)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ResolveError.httpStatus(http.statusCode)
        }
        guard let resolved = downloadURL(fromAPI: data) else { throw ResolveError.noFile(slug: slug) }
        return Resolution(
            downloadURL: resolved.url,
            source: .addons(listing: url.absoluteString, slug: slug),
            displayName: resolved.name,
            version: resolved.version)
    }

    /// Download a package. Separate from `resolve` so a re-install from a
    /// remembered listing reuses the resolution step.
    static func download(
        _ url: URL,
        fetch: (URL) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(from: $0) }
    ) async throws -> Data {
        let (data, response) = try await fetch(url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ResolveError.httpStatus(http.statusCode)
        }
        return data
    }
}
