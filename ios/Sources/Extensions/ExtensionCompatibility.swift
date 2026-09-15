//  ExtensionCompatibility.swift
//  What this extension asks for that WebKit will not give it.
//
//  WebKit loads the same package Firefox and Chrome load, and then silently
//  does less with it. `browser.sidebarAction.open()` is not an error — the
//  namespace is simply not there, so the call throws inside the extension's
//  own background script where nobody sees it, and the extension appears to
//  be installed and broken. That is the worst possible failure mode for
//  somebody who has just been asked to grant it access to every site they
//  visit.
//
//  So: before anything is loaded, read the manifest and the scripts and say
//  what is missing. The report is shown on the install sheet next to the
//  permission list, and kept afterwards so Settings can show it again.
//
//  **This is a static scan and it says so on the screen.** It reads the
//  manifest keys, the declared permissions, and a regex over `browser.X` /
//  `chrome.X` in the package's JavaScript. It cannot see through minification
//  that rewrites `chrome.tabs` to `c[t]`, it cannot tell a live call from a
//  feature-detection branch (`if (browser.sidebarAction)` is exactly how a
//  well-written cross-browser extension copes, and will be reported anyway),
//  and it knows nothing about what the extension does at runtime. It is a
//  warning, not a verdict — which is why nothing here refuses an install.

import Foundation

struct ExtensionCompatibilityReport: Codable, Equatable, Sendable {
    var findings: [Finding] = []
    /// How many JavaScript files the namespace scan actually read.
    var scannedFileCount: Int = 0
    /// Every `browser.`/`chrome.` namespace seen, supported or not.
    var detectedNamespaces: [String] = []

    enum Severity: String, Codable, Comparable, Sendable {
        /// The extension will not load, or the only thing it offers is absent.
        case blocking
        /// It loads and part of it works.
        case degraded
        /// Worth knowing, nothing is lost.
        case note

        private var rank: Int {
            switch self {
            case .blocking: return 0
            case .degraded: return 1
            case .note: return 2
            }
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }

        var title: String {
            switch self {
            case .blocking: return "Will not work"
            case .degraded: return "Partly unsupported"
            case .note: return "Note"
            }
        }

        var symbol: String {
            switch self {
            case .blocking: return "xmark.octagon.fill"
            case .degraded: return "exclamationmark.triangle.fill"
            case .note: return "info.circle"
            }
        }
    }

    enum Kind: String, Codable, Sendable {
        case permission
        case manifestKey
        case api
        case background
        case manifestVersion
    }

    struct Finding: Codable, Equatable, Identifiable, Sendable {
        /// Stable across runs — the kind and subject, so SwiftUI's `ForEach`
        /// does not re-animate the whole list when one finding changes.
        var id: String { "\(kind.rawValue):\(subject)" }
        var severity: Severity
        var kind: Kind
        /// The thing itself: `webRequestBlocking`, `sidebarAction`.
        var subject: String
        var detail: String
        /// Files the scan saw it in. Empty for manifest-level findings.
        var locations: [String] = []
    }

    /// Nothing in the package that WebKit will refuse outright.
    var isLoadable: Bool { !findings.contains { $0.severity == .blocking } }

    var worstSeverity: Severity? { findings.map(\.severity).min() }

    var blockingCount: Int { findings.count { $0.severity == .blocking } }
    var degradedCount: Int { findings.count { $0.severity == .degraded } }

    /// One line for a list row.
    var summary: String {
        guard !findings.isEmpty else { return "No unsupported APIs found" }
        if blockingCount > 0 {
            return "\(blockingCount) unsupported "
                + (blockingCount == 1 ? "feature" : "features") + " it depends on"
        }
        if degradedCount > 0 {
            return "\(degradedCount) unsupported "
                + (degradedCount == 1 ? "API" : "APIs")
        }
        return "\(findings.count) note" + (findings.count == 1 ? "" : "s")
    }
}

enum ExtensionCompatibility {

    // MARK: What WebKit has

    /// WebKit's own permission vocabulary, transcribed from the
    /// `WKWebExtensionPermission` constants in `WebKit/WKWebExtensionPermission.h`.
    ///
    /// Deliberately sourced from the *framework* rather than from Apple's
    /// prose: this is the list WebKit will actually match a manifest against,
    /// so a permission missing from it is a permission that does nothing, and
    /// the list cannot drift away from the SDK without the SDK changing.
    static let supportedPermissions: Set<String> = [
        "activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies",
        "declarativeNetRequest", "declarativeNetRequestFeedback",
        "declarativeNetRequestWithHostAccess", "menus", "nativeMessaging", "scripting",
        "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest",
    ]

    /// The `browser.`/`chrome.` namespaces WebKit implements.
    static let supportedNamespaces: Set<String> = [
        "action", "alarms", "browserAction", "commands", "contextMenus", "cookies",
        "declarativeNetRequest", "dom", "extension", "i18n", "menus", "pageAction",
        "permissions", "runtime", "scripting", "storage", "tabs", "webNavigation",
        "webRequest", "windows",
    ]

    /// Namespaces we can say something specific about. Anything not here and
    /// not supported still gets reported, with a generic line.
    static let namespaceNotes: [String: String] = [
        "sidebarAction":
            "Firefox's sidebar. WebKit has no sidebar surface, so the extension's sidebar "
            + "panel will never be shown.",
        "sidePanel":
            "Chrome's side panel. WebKit has no side-panel surface.",
        "contextualIdentities":
            "Firefox containers. Zen isolates cookies per space with a separate "
            + "WKWebsiteDataStore, but the API itself is absent.",
        "browsingData": "Clearing history, cache and cookies from an extension is not exposed.",
        "bookmarks": "Zen's bookmarks are the app's own; no extension API reaches them.",
        "history": "The browsing history is not readable or writable by an extension.",
        "downloads": "WebKit exposes no download management to extensions.",
        "management": "Extensions cannot enumerate or control other extensions.",
        "privacy": "Browser privacy settings are not extension-controllable.",
        "proxy": "Proxy configuration is a system setting on iOS.",
        "sessions": "Recently-closed tabs and devices are not exposed.",
        "topSites": "The most-visited list is not exposed.",
        "idle": "User idle state is not exposed.",
        "notifications": "Extension-posted system notifications are not supported on iOS.",
        "identity": "The OAuth helper (`launchWebAuthFlow`) is absent.",
        "pageCapture": "Saving a page as MHTML is not supported.",
        "tabCapture": "Capturing tab media is not supported.",
        "webRequestAuthProvider": "Intercepting authentication challenges is not supported.",
        "declarativeContent": "Use declarativeNetRequest; this Chrome API is absent.",
        "offscreen": "Chrome's offscreen documents are absent.",
        "devtools": "iOS has no extension developer tools panel.",
        "theme": "Firefox's dynamic theming API is absent; Zen themes its own chrome.",
        "search": "The search-engine API is absent.",
        "find": "Firefox's find-in-page API is absent; Zen's own find bar is unaffected.",
        "omnibox": "Address-bar keyword extensions are not supported.",
        "userScripts": "The user-script API is absent.",
        "pkcs11": "Security-device management is desktop-only.",
        "browserSettings": "Firefox's settings API is absent.",
        "captivePortal": "Firefox's captive-portal API is absent.",
        "dns": "Firefox's DNS resolution API is absent.",
        "geolocation": "Page geolocation still works; the extension permission does nothing.",
        "gcm": "Google Cloud Messaging is absent.",
        "printing": "Printing is not exposed to extensions.",
        "topLevelFrame": "Not a WebExtension API.",
    ]

    /// Manifest keys that describe a surface WebKit does not have.
    static let unsupportedManifestKeys: [String: String] = [
        "sidebar_action":
            "Declares a sidebar panel. WebKit has no sidebar, so this part of the extension "
            + "will not appear.",
        "side_panel": "Chrome's side panel. WebKit has no side-panel surface.",
        "devtools_page": "iOS has no extension developer tools panel.",
        "omnibox": "Address-bar keyword extensions are not supported.",
        "chrome_settings_overrides":
            "Overriding the search engine or home page from an extension is not supported.",
        "user_scripts": "The user-script API is absent.",
        "protocol_handlers": "Custom protocol handlers are not supported.",
        "chrome_url_overrides":
            "Only the new-tab override is honoured, and only with the owner's consent; "
            + "history and bookmarks page overrides are ignored.",
    ]

    // MARK: The scan

    /// Look at everything in `directory` and report.
    ///
    /// `readFile` is injected so the tests can scan an in-memory package and so
    /// the install sheet can scan an archive that has not been unpacked yet.
    static func scan(
        manifest: ExtensionManifest,
        javascriptFiles: [String: String]
    ) -> ExtensionCompatibilityReport {
        var findings: [ExtensionCompatibilityReport.Finding] = []

        findings += manifestVersionFindings(manifest)
        findings += backgroundFindings(manifest)
        findings += permissionFindings(manifest)
        findings += manifestKeyFindings(manifest)

        let scan = scanNamespaces(in: javascriptFiles)
        findings += scan.findings
        findings += blockingWebRequestFindings(manifest, files: javascriptFiles)

        // Blocking first, then alphabetically inside a severity, so the list
        // reads worst-first and does not reshuffle between runs.
        findings.sort {
            $0.severity == $1.severity
                ? $0.subject.localizedCaseInsensitiveCompare($1.subject) == .orderedAscending
                : $0.severity < $1.severity
        }
        // A subject can be reported by both the permission pass and the API
        // pass (`webRequest` is the common one); keep the more severe.
        var seen: Set<String> = []
        findings = findings.filter { seen.insert($0.subject).inserted }

        return ExtensionCompatibilityReport(
            findings: findings,
            scannedFileCount: javascriptFiles.count,
            detectedNamespaces: scan.namespaces.sorted())
    }

    /// Read the JavaScript out of an unpacked extension directory.
    ///
    /// Everything with a `.js` extension, not only the declared entry points:
    /// a background script that `importScripts()`es its real implementation is
    /// the normal shape of a bundled extension, and scanning only what the
    /// manifest names would miss all of it. Files over 4 MB are skipped —
    /// past that it is a bundled library, and the regex cost stops being free.
    static func javascript(in directory: URL, limit: Int = 200) -> [String: String] {
        let fm = FileManager.default
        guard
            let walker = fm.enumerator(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return [:] }
        var result: [String: String] = [:]
        let base = directory.standardizedFileURL.path
        for case let url as URL in walker {
            guard result.count < limit else { break }
            guard url.pathExtension.lowercased() == "js" else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= 4_194_304 else {
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var relative = url.standardizedFileURL.path
            if relative.hasPrefix(base) { relative = String(relative.dropFirst(base.count + 1)) }
            result[relative] = text
        }
        return result
    }

    // MARK: Individual passes

    private static func manifestVersionFindings(_ manifest: ExtensionManifest)
        -> [ExtensionCompatibilityReport.Finding]
    {
        guard manifest.manifestVersion == 2 else { return [] }
        return [
            .init(
                severity: .note, kind: .manifestVersion, subject: "manifest_version 2",
                detail:
                    "WebKit loads manifest v2, but both Chrome and Firefox are retiring it — "
                    + "expect this extension to stop being updated.")
        ]
    }

    private static func backgroundFindings(_ manifest: ExtensionManifest)
        -> [ExtensionCompatibilityReport.Finding]
    {
        guard manifest.backgroundIsPersistent else { return [] }
        return [
            .init(
                severity: .blocking, kind: .background, subject: "persistent background page",
                detail:
                    "iOS refuses to load an extension whose background page is persistent "
                    + "(WKWebExtensionErrorInvalidBackgroundPersistence). Only macOS allows it.")
        ]
    }

    private static func permissionFindings(_ manifest: ExtensionManifest)
        -> [ExtensionCompatibilityReport.Finding]
    {
        let declared = manifest.permissions + manifest.optionalPermissions
        var findings: [ExtensionCompatibilityReport.Finding] = []
        for permission in Set(declared).sorted() {
            guard !supportedPermissions.contains(permission) else { continue }
            let severity: ExtensionCompatibilityReport.Severity =
                permission == "webRequestBlocking" ? .blocking : .degraded
            let detail: String
            if permission == "webRequestBlocking" {
                detail =
                    "Blocking webRequest — the API a Firefox content blocker cancels requests "
                    + "with. WebKit exposes webRequest for observation only; blocking has to "
                    + "go through declarativeNetRequest instead."
            } else {
                detail =
                    namespaceNotes[permission]
                    ?? "WebKit does not implement this permission, so it grants nothing."
            }
            findings.append(
                .init(
                    severity: severity, kind: .permission, subject: permission, detail: detail))
        }
        return findings
    }

    private static func manifestKeyFindings(_ manifest: ExtensionManifest)
        -> [ExtensionCompatibilityReport.Finding]
    {
        var findings: [ExtensionCompatibilityReport.Finding] = []
        for key in manifest.declaredKeys {
            guard let note = unsupportedManifestKeys[key] else { continue }
            // A sidebar is only fatal when it is the *only* way in. An
            // extension with both a toolbar action and a sidebar loses the
            // sidebar and keeps working.
            let severity: ExtensionCompatibilityReport.Severity =
                (key == "sidebar_action" || key == "side_panel") && manifest.action == nil
                ? .blocking : .degraded
            findings.append(
                .init(severity: severity, kind: .manifestKey, subject: key, detail: note))
        }
        return findings
    }

    private static func blockingWebRequestFindings(
        _ manifest: ExtensionManifest, files: [String: String]
    ) -> [ExtensionCompatibilityReport.Finding] {
        // Already reported through the permission, which is the reliable signal.
        guard !(manifest.permissions + manifest.optionalPermissions).contains("webRequestBlocking")
        else { return [] }
        let locations = files.filter { _, source in
            guard source.contains("webRequest") else { return false }
            return source.contains("\"blocking\"") || source.contains("'blocking'")
        }.keys.sorted()
        guard !locations.isEmpty else { return [] }
        return [
            .init(
                severity: .degraded, kind: .api, subject: "webRequest (blocking)",
                detail:
                    "A webRequest listener asks for \"blocking\". WebKit's webRequest is "
                    + "observational: the listener runs, but returning `{cancel: true}` or a "
                    + "redirect has no effect.",
                locations: Array(locations.prefix(6)))
        ]
    }

    // MARK: Namespace scan

    /// `browser.foo` / `chrome.foo`, with the namespace captured.
    ///
    /// Word-boundary anchored on the left so `myBrowser.tabs` is not a match,
    /// and the property may be followed by anything — a call, a `.addListener`,
    /// or a bare reference in a feature test.
    private static let namespaceExpression = try? NSRegularExpression(
        pattern: "(?<![\\w$.])(?:browser|chrome)\\s*\\.\\s*([A-Za-z_$][\\w$]*)")

    static func scanNamespaces(in files: [String: String])
        -> (findings: [ExtensionCompatibilityReport.Finding], namespaces: Set<String>)
    {
        guard let expression = namespaceExpression else { return ([], []) }
        var seen: [String: Set<String>] = [:]
        for (path, source) in files {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            expression.enumerateMatches(in: source, range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1,
                    let captured = Range(match.range(at: 1), in: source)
                else { return }
                seen[String(source[captured]), default: []].insert(path)
            }
        }

        var findings: [ExtensionCompatibilityReport.Finding] = []
        for (namespace, paths) in seen {
            guard !supportedNamespaces.contains(namespace) else { continue }
            // `browser.runtime.id` and friends are properties, not namespaces;
            // anything that is not a known API and is not in the notes table is
            // reported generically rather than confidently.
            let detail =
                namespaceNotes[namespace]
                ?? "WebKit does not implement `browser.\(namespace)`; calls to it will fail "
                    + "inside the extension."
            findings.append(
                .init(
                    severity: .degraded, kind: .api, subject: namespace, detail: detail,
                    locations: Array(paths.sorted().prefix(6))))
        }
        return (findings, Set(seen.keys))
    }
}
