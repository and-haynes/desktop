//  InstalledExtension.swift
//  The record of one installed extension — everything Settings shows and
//  everything the runtime needs to reconstruct a `WKWebExtensionContext`.
//
//  Deliberately a plain `Codable` value with no WebKit types in it. The list
//  has to load, render and be editable on iOS 17, where `WKWebExtension` does
//  not exist at all: someone who installed an extension, then rolled back a
//  beta, should still see what is installed and be able to remove it rather
//  than meet an empty screen. Everything that needs the framework is gated
//  behind `@available(iOS 18.4, *)` in `ExtensionRuntime`, and this file is
//  what the two halves agree on.

import Foundation

struct InstalledExtension: Codable, Equatable, Identifiable, Sendable {
    /// The unpacked directory's name under Application Support, and the
    /// identity the runtime keys its contexts by.
    var id: String
    var name: String
    var version: String
    var descriptionText: String?
    var manifestVersion: Int

    var installedAt: Date = Date()
    var updatedAt: Date = Date()
    var source: Source

    /// Off means the context is unloaded from every controller. The package
    /// stays on disk — disabling is not removing.
    var isEnabled: Bool = true

    /// What the manifest asked for, kept so the permissions editor can offer
    /// the full list rather than only what is currently granted.
    var requestedPermissions: [String] = []
    var optionalPermissions: [String] = []
    var requestedHostPatterns: [String] = []
    var optionalHostPatterns: [String] = []

    /// What the owner said yes and no to. A permission in neither is
    /// *unrequested* — WebKit will ask at the moment it is needed.
    var grantedPermissions: [String] = []
    var deniedPermissions: [String] = []
    var grantedHostPatterns: [String] = []
    var deniedHostPatterns: [String] = []

    /// Per-site overrides on top of the patterns, keyed by host. This is the
    /// "on this site" control: it is the thing people actually reach for, and
    /// it maps onto `setPermissionStatus(_:for:)` with a single-host pattern.
    var siteAccess: [String: SiteAccess] = [:]

    var compatibility: ExtensionCompatibilityReport = .init()

    var hasAction: Bool = false
    var hasOptionsPage: Bool = false
    var hasContentScripts: Bool = false
    var hasDeclarativeNetRequest: Bool = false
    /// Relative path to the best icon in the package, for the settings row.
    var iconPath: String?

    enum SiteAccess: String, Codable, Sendable {
        case allow
        case deny
    }

    enum Source: Codable, Equatable, Sendable {
        /// Picked from Files or received through the share sheet.
        case file(name: String)
        /// Fetched from addons.mozilla.org; the listing URL, not the XPI, so
        /// "update from source" can resolve the current version.
        case addons(listing: String, slug: String)
        /// One of the app's own fixture extensions.
        case bundled(name: String)

        var displayName: String {
            switch self {
            case .file(let name): return name
            case .addons(_, let slug): return "addons.mozilla.org/\(slug)"
            case .bundled(let name): return "Built in — \(name)"
            }
        }

        /// Whether "Update from source" can do anything. A file we no longer
        /// hold cannot be re-read; a bundled fixture can be re-copied; an AMO
        /// listing can be re-fetched.
        var isRefreshable: Bool {
            switch self {
            case .file: return false
            case .addons, .bundled: return true
            }
        }
    }

    /// Build a record from a freshly parsed package. Grants start empty — the
    /// install sheet fills them in from what the owner ticked.
    init(manifest: ExtensionManifest, source: Source, report: ExtensionCompatibilityReport) {
        id = manifest.identifier
        name = manifest.name
        version = manifest.version
        descriptionText = manifest.descriptionText
        manifestVersion = manifest.manifestVersion
        self.source = source
        requestedPermissions = manifest.permissions
        optionalPermissions = manifest.optionalPermissions
        requestedHostPatterns = manifest.hostPermissions
        optionalHostPatterns = manifest.optionalHostPermissions
        compatibility = report
        hasAction = manifest.action != nil
        hasOptionsPage = manifest.optionsPage != nil
        hasContentScripts = !manifest.contentScripts.isEmpty
        hasDeclarativeNetRequest = !manifest.declarativeNetRequestRulesets.isEmpty
        iconPath = manifest.action?.defaultIcons.bestPath ?? manifest.icons.bestPath
    }

    /// Carry an owner's decisions across an update. A permission the new
    /// version no longer asks for is dropped rather than left granted.
    mutating func adoptDecisions(from previous: InstalledExtension) {
        let requestable = Set(requestedPermissions + optionalPermissions)
        grantedPermissions = previous.grantedPermissions.filter(requestable.contains)
        deniedPermissions = previous.deniedPermissions.filter(requestable.contains)
        let patterns = Set(requestedHostPatterns + optionalHostPatterns)
        grantedHostPatterns = previous.grantedHostPatterns.filter(patterns.contains)
        deniedHostPatterns = previous.deniedHostPatterns.filter(patterns.contains)
        siteAccess = previous.siteAccess
        isEnabled = previous.isEnabled
        installedAt = previous.installedAt
        updatedAt = Date()
    }

    /// A one-line summary of host access for the settings row.
    var hostAccessSummary: String {
        if grantedHostPatterns.contains("<all_urls>")
            || grantedHostPatterns.contains(where: { $0.hasPrefix("*://*/") })
        {
            return "All sites"
        }
        let hosts = Set(grantedHostPatterns.compactMap(InstalledExtension.hostLabel))
        switch hosts.count {
        case 0: return siteAccess.isEmpty ? "No site access" : "Only sites you chose"
        case 1: return hosts.first ?? "1 site"
        default: return "\(hosts.count) sites"
        }
    }

    /// The readable middle of a match pattern: `*://*.example.com/*` → `example.com`.
    static func hostLabel(_ pattern: String) -> String? {
        guard pattern != "<all_urls>" else { return nil }
        guard let separator = pattern.range(of: "://") else { return nil }
        let rest = pattern[separator.upperBound...]
        let host = rest.prefix { $0 != "/" }
        guard !host.isEmpty, host != "*" else { return nil }
        return String(host).replacingOccurrences(of: "*.", with: "")
    }

    /// The pattern used when the owner allows or denies one specific site.
    static func pattern(forHost host: String) -> String { "*://\(host)/*" }
}

extension [Int: String] {
    /// The largest declared icon, which is what a 44pt settings row wants.
    /// Size `0` is the key `ExtensionManifest` uses for a bare `default_icon`
    /// string, and loses to any real size.
    var bestPath: String? {
        let sized = filter { $0.key > 0 }
        if let best = sized.max(by: { $0.key < $1.key }) { return best.value }
        return self[0]
    }
}
