//  ExtensionManifest.swift
//  Reading a WebExtension's `manifest.json` ourselves, before WebKit sees it.
//
//  WebKit parses the manifest too — `WKWebExtension` exposes `manifest`,
//  `requestedPermissions` and the rest once it has loaded a package. So why
//  parse it twice?
//
//  Because everything worth telling someone happens *before* the load. The
//  install sheet has to name the permissions and the hosts an extension wants
//  while the owner can still say no, and the compatibility report has to say
//  which of those WebKit will quietly ignore — and `WKWebExtension` only
//  reports the permissions it *recognises*, which is precisely the wrong half.
//  An extension asking for `contextualIdentities` and `webRequestBlocking`
//  loads with an empty complaint and then does nothing; the only way to say so
//  in advance is to read the file.
//
//  It is also what makes the parser testable at all: `WKWebExtension` needs
//  iOS 18.4 and a real package on disk, where this is a value type over `Data`.

import Foundation

/// A parsed `manifest.json`, in the shape the install flow needs.
struct ExtensionManifest: Equatable, Sendable {
    /// 2 or 3. Anything else is rejected — see `parse`.
    var manifestVersion: Int
    var name: String
    var version: String
    var descriptionText: String?

    /// API permissions only: the host patterns MV2 mixes into the same array
    /// are split out into `hostPermissions` (see `Self.isHostPattern`).
    var permissions: [String]
    var optionalPermissions: [String]
    /// MV3's `host_permissions`, plus whatever was extracted from MV2's
    /// `permissions`.
    var hostPermissions: [String]
    var optionalHostPermissions: [String]

    var contentScripts: [ContentScript]
    /// Every background entry point, MV2 `scripts`/`page` or MV3
    /// `service_worker`/`scripts`, as paths relative to the package root.
    var backgroundScripts: [String]
    var backgroundIsServiceWorker: Bool
    var backgroundIsPersistent: Bool

    var action: Action?
    var optionsPage: String?
    var declarativeNetRequestRulesets: [Ruleset]
    var icons: [Int: String]

    /// Firefox's `browser_specific_settings.gecko.id`, when the package
    /// carries one.
    var geckoID: String?
    /// Firefox's `strict_min_version`, which is the usual reason a package
    /// declines to install elsewhere.
    var geckoStrictMinVersion: String?

    /// Keys the manifest declares that we recognise as WebExtension top-level
    /// keys. Kept so the compatibility scanner can report on manifest *keys*
    /// (`sidebar_action`) and not only on permissions.
    var declaredKeys: [String]

    struct ContentScript: Equatable, Sendable {
        var matches: [String]
        var excludeMatches: [String]
        var js: [String]
        var css: [String]
        var runAt: String?
        var allFrames: Bool
    }

    struct Action: Equatable, Sendable {
        /// `action` (MV3), `browser_action` or `page_action` (MV2).
        var key: String
        var defaultTitle: String?
        var defaultPopup: String?
        var defaultIcons: [Int: String]
    }

    struct Ruleset: Equatable, Sendable {
        var id: String
        var path: String
        var enabled: Bool
    }

    // MARK: Identity

    /// The directory an installed copy lives under.
    ///
    /// Firefox packages carry an explicit id; Chrome's comes from the CRX
    /// signing key and is not in the manifest at all. Rather than invent a
    /// fake extension id, the fallback is a slug of the name — stable across
    /// re-installs of the same extension, which is what "update from source"
    /// needs, and legible in a directory listing, which the id hash is not.
    var identifier: String {
        if let geckoID, !geckoID.isEmpty { return ExtensionManifest.slug(geckoID) }
        return ExtensionManifest.slug(name)
    }

    /// Reduce anything to a directory name.
    ///
    /// The dot has to survive — a Firefox id is `ublock0@raymondhill.net` and
    /// `ublock0-raymondhill.net` is the readable answer — which means `..` can
    /// survive too, and `..` is the one sequence that climbs out of a
    /// directory. So a run of dots is collapsed to a separator, and the result
    /// cannot begin or end with one either.
    static func slug(_ input: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let mapped = String(input.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        var cleaned = mapped.lowercased()
        while cleaned.contains("..") {
            cleaned = cleaned.replacingOccurrences(of: "..", with: "-")
        }
        let collapsed = cleaned
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return trimmed.isEmpty ? "extension" : String(trimmed.prefix(96))
    }

    // MARK: Parsing

    enum ParseError: LocalizedError, Equatable {
        case notJSON
        case notAnObject
        case missingManifestVersion
        case unsupportedManifestVersion(Int)
        case missingName
        case missingVersion

        var errorDescription: String? {
            switch self {
            case .notJSON:
                return "manifest.json is not valid JSON."
            case .notAnObject:
                return "manifest.json is not a JSON object."
            case .missingManifestVersion:
                return "manifest.json has no manifest_version."
            case .unsupportedManifestVersion(let version):
                return
                    "manifest_version \(version) is not a WebExtension manifest — "
                    + "WebKit loads version 2 and 3."
            case .missingName:
                return "manifest.json has no name."
            case .missingVersion:
                return "manifest.json has no version."
            }
        }
    }

    static func parse(_ data: Data) throws -> ExtensionManifest {
        let any: Any
        do {
            // `.fragmentsAllowed` so a manifest that is a bare string fails as
            // "not an object" rather than as "not JSON" — the message matters.
            any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ParseError.notJSON
        }
        guard let root = any as? [String: Any] else { throw ParseError.notAnObject }

        guard let rawVersion = root["manifest_version"] else {
            throw ParseError.missingManifestVersion
        }
        let manifestVersion = Self.int(rawVersion) ?? 0
        guard manifestVersion == 2 || manifestVersion == 3 else {
            throw ParseError.unsupportedManifestVersion(manifestVersion)
        }
        guard let name = Self.localisedString(root["name"]), !name.isEmpty else {
            throw ParseError.missingName
        }
        guard let version = Self.string(root["version"]), !version.isEmpty else {
            throw ParseError.missingVersion
        }

        let rawPermissions = Self.stringArray(root["permissions"])
        let rawOptional = Self.stringArray(root["optional_permissions"])

        var hosts = rawPermissions.filter(Self.isHostPattern)
        hosts += Self.stringArray(root["host_permissions"])
        var optionalHosts = rawOptional.filter(Self.isHostPattern)
        optionalHosts += Self.stringArray(root["optional_host_permissions"])

        let background = Self.background(root["background"])
        let gecko = Self.gecko(root)

        return ExtensionManifest(
            manifestVersion: manifestVersion,
            name: name,
            version: version,
            descriptionText: Self.localisedString(root["description"]),
            permissions: rawPermissions.filter { !Self.isHostPattern($0) },
            optionalPermissions: rawOptional.filter { !Self.isHostPattern($0) },
            hostPermissions: Self.unique(hosts),
            optionalHostPermissions: Self.unique(optionalHosts),
            contentScripts: Self.contentScripts(root["content_scripts"]),
            backgroundScripts: background.scripts,
            backgroundIsServiceWorker: background.isServiceWorker,
            backgroundIsPersistent: background.isPersistent,
            action: Self.action(root),
            optionsPage: Self.optionsPage(root),
            declarativeNetRequestRulesets: Self.rulesets(root["declarative_net_request"]),
            icons: Self.icons(root["icons"]),
            geckoID: gecko.id,
            geckoStrictMinVersion: gecko.strictMinVersion,
            declaredKeys: root.keys.sorted())
    }

    /// A permissions entry that is really a match pattern. MV2 puts both in one
    /// array; `<all_urls>` and anything with a scheme separator is a host.
    static func isHostPattern(_ entry: String) -> Bool {
        if entry == "<all_urls>" { return true }
        if entry.contains("://") { return true }
        // `file:///*` and friends have the separator; a bare `*://*/*` does not
        // parse as one but is unmistakably a pattern.
        return entry.hasPrefix("*://")
    }

    // MARK: Field readers
    //
    // Everything below is deliberately forgiving. A manifest in the wild is
    // whatever a build script produced: `manifest_version` arrives as a string
    // from at least one popular bundler, `name` is often an `__MSG_…__`
    // placeholder, and `background.scripts` may be a bare string. None of that
    // is a reason to refuse to show someone what they are about to install —
    // WebKit gets the final say on whether the package loads.

    private static func int(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? Double { return Int(value) }
        if let value = any as? String { return Int(value) }
        return nil
    }

    private static func string(_ any: Any?) -> String? {
        if let value = any as? String { return value }
        if let value = any as? NSNumber { return value.stringValue }
        return nil
    }

    /// A name or description may be an `__MSG_name__` placeholder resolved from
    /// `_locales`. We do not run the localisation machinery — WebKit does, and
    /// its `displayName` is what the installed list shows. For the install
    /// sheet the placeholder is stripped to something readable rather than
    /// shown raw.
    private static func localisedString(_ any: Any?) -> String? {
        guard let raw = string(any) else { return nil }
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
        let key = raw.dropFirst(6).dropLast(2)
        return key.isEmpty ? raw : String(key).replacingOccurrences(of: "_", with: " ")
    }

    private static func stringArray(_ any: Any?) -> [String] {
        if let values = any as? [String] { return values }
        if let value = any as? String { return [value] }
        if let values = any as? [Any] { return values.compactMap { $0 as? String } }
        return []
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func contentScripts(_ any: Any?) -> [ContentScript] {
        guard let entries = any as? [Any] else { return [] }
        return entries.compactMap { entry in
            guard let dict = entry as? [String: Any] else { return nil }
            return ContentScript(
                matches: stringArray(dict["matches"]),
                excludeMatches: stringArray(dict["exclude_matches"]),
                js: stringArray(dict["js"]),
                css: stringArray(dict["css"]),
                runAt: string(dict["run_at"]),
                allFrames: (dict["all_frames"] as? Bool) ?? false)
        }
    }

    private static func background(_ any: Any?)
        -> (scripts: [String], isServiceWorker: Bool, isPersistent: Bool)
    {
        guard let dict = any as? [String: Any] else { return ([], false, false) }
        var scripts = stringArray(dict["scripts"])
        var isServiceWorker = false
        if let worker = string(dict["service_worker"]) {
            scripts.append(worker)
            isServiceWorker = true
        }
        if let page = string(dict["page"]) { scripts.append(page) }
        // MV2 defaults `persistent` to true when `scripts` is used; MV3 has no
        // persistent background at all. iOS rejects persistent background
        // content outright (`WKWebExtensionErrorInvalidBackgroundPersistence`),
        // so this is worth reporting rather than discovering at load.
        let persistent: Bool
        if let declared = dict["persistent"] as? Bool {
            persistent = declared
        } else {
            persistent = !isServiceWorker && !scripts.isEmpty && dict["type"] == nil
        }
        return (unique(scripts), isServiceWorker, persistent)
    }

    private static func action(_ root: [String: Any]) -> Action? {
        for key in ["action", "browser_action", "page_action"] {
            guard let dict = root[key] as? [String: Any] else { continue }
            return Action(
                key: key,
                defaultTitle: localisedString(dict["default_title"]),
                defaultPopup: string(dict["default_popup"]),
                defaultIcons: icons(dict["default_icon"]))
        }
        // A declared-but-empty `action` is how an MV3 extension says "give me a
        // toolbar button with the default icon".
        if root["action"] != nil {
            return Action(key: "action", defaultTitle: nil, defaultPopup: nil, defaultIcons: [:])
        }
        return nil
    }

    private static func optionsPage(_ root: [String: Any]) -> String? {
        if let ui = root["options_ui"] as? [String: Any], let page = string(ui["page"]) {
            return page
        }
        return string(root["options_page"])
    }

    private static func rulesets(_ any: Any?) -> [Ruleset] {
        guard let dict = any as? [String: Any],
            let entries = dict["rule_resources"] as? [Any]
        else { return [] }
        return entries.compactMap { entry in
            guard let rule = entry as? [String: Any], let path = string(rule["path"]) else {
                return nil
            }
            return Ruleset(
                id: string(rule["id"]) ?? path,
                path: path,
                enabled: (rule["enabled"] as? Bool) ?? false)
        }
    }

    private static func icons(_ any: Any?) -> [Int: String] {
        // `default_icon` is allowed to be a bare path rather than a size map.
        if let path = string(any) { return [0: path] }
        guard let dict = any as? [String: Any] else { return [:] }
        var result: [Int: String] = [:]
        for (key, value) in dict {
            guard let size = Int(key), let path = string(value) else { continue }
            result[size] = path
        }
        return result
    }

    private static func gecko(_ root: [String: Any]) -> (id: String?, strictMinVersion: String?) {
        let container =
            (root["browser_specific_settings"] as? [String: Any])
            ?? (root["applications"] as? [String: Any])
        guard let gecko = container?["gecko"] as? [String: Any] else { return (nil, nil) }
        return (string(gecko["id"]), string(gecko["strict_min_version"]))
    }
}
