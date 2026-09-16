//  ExtensionStore.swift
//  What is installed, where it lives on disk, and what it is allowed to do.
//
//  Installing is two steps on purpose. `prepare` unpacks into a staging
//  directory, parses the manifest and runs the compatibility scan; nothing is
//  registered and nothing is loaded. The install sheet then shows what the
//  package wants and what WebKit will ignore, and only a deliberate "Install"
//  calls `commit`, which moves the staged directory into place and writes the
//  record. Cancelling deletes the staging directory and leaves no trace.
//
//  The alternative — install, then ask — is how a browser ends up with an
//  extension somebody did not agree to, sitting in the list with its content
//  scripts already registered.

import Foundation
import SwiftUI

/// An unpacked, parsed, scanned package that nobody has agreed to yet.
struct PreparedExtension: Identifiable, Equatable {
    var id: String { record.id }
    var record: InstalledExtension
    var manifest: ExtensionManifest
    /// The per-install scratch directory. Deleting this is what "cancel" does.
    var stagingRoot: URL
    /// Where `manifest.json` actually is, which may be one level inside
    /// `stagingRoot` — a directory copy nests, an archive unpack does not.
    var packageURL: URL
    /// An install that will overwrite an existing one of the same id.
    var replacing: InstalledExtension?

    var isUpdate: Bool { replacing != nil }
}

@MainActor
final class ExtensionStore: ObservableObject {
    @Published private(set) var extensions: [InstalledExtension] = []
    /// The last failure, for the banner on the extensions screen. Cleared by
    /// the view once shown.
    @Published var lastError: String?

    /// `Application Support/Zen/Extensions`. Every unpacked package is a
    /// directory under here named for its identifier.
    let root: URL
    private let file: JSONFileStore<[InstalledExtension]>

    init(file: JSONFileStore<[InstalledExtension]>? = nil, root: URL? = nil) {
        self.file = file ?? JSONFileStore<[InstalledExtension]>(name: "extensions.json")
        self.root =
            root ?? JSONFileStore<[InstalledExtension]>.defaultDirectory
            .appendingPathComponent("Extensions", isDirectory: true)
        extensions = self.file.load() ?? []
        pruneMissingPackages()
        clearStaging()
    }

    // MARK: Layout

    func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private var stagingRoot: URL {
        root.appendingPathComponent("_staging", isDirectory: true)
    }

    /// A record whose directory has gone — deleted by hand, or lost to a
    /// restore — is a row that can only ever fail to load. Drop it at launch
    /// rather than showing something that is not there.
    private func pruneMissingPackages() {
        let fm = FileManager.default
        let survivors = extensions.filter {
            fm.fileExists(atPath: directory(for: $0.id).appendingPathComponent("manifest.json").path)
        }
        guard survivors.count != extensions.count else { return }
        extensions = survivors
        persist()
    }

    func record(id: String) -> InstalledExtension? { extensions.first { $0.id == id } }

    var enabledExtensions: [InstalledExtension] { extensions.filter(\.isEnabled) }

    // MARK: Preparing an install

    /// From archive bytes — an XPI, a CRX, or a plain ZIP.
    func prepare(archive data: Data, source: InstalledExtension.Source) throws -> PreparedExtension
    {
        let zip = try ExtensionArchive.strippingCRXHeader(data)
        guard ExtensionArchive.looksLikeZIP(zip) else {
            throw ExtensionArchive.ArchiveError.notAnArchive
        }
        let staging = try freshStagingDirectory()
        do {
            try ExtensionArchive.unpack(zip, to: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return try prepared(from: staging, source: source)
    }

    /// From a directory the owner picked — an unpacked extension, or a Safari
    /// web extension's resource bundle.
    func prepare(directory: URL, source: InstalledExtension.Source) throws -> PreparedExtension {
        let staging = try freshStagingDirectory()
        // The Files picker hands back a security-scoped URL; without the
        // bracket the copy fails with "no such file" on a perfectly real path.
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        // A Safari web extension nests the WebExtension under Resources/.
        let manifestParent = Self.resolvePackageRoot(directory)
        do {
            try ExtensionArchive.copyDirectory(at: manifestParent, to: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return try prepared(from: staging, source: source)
    }

    /// `.appex`/`.bundle` layouts put `manifest.json` under `Resources`; a
    /// plain unpacked extension has it at the top.
    static func resolvePackageRoot(_ directory: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) {
            return directory
        }
        let resources = directory.appendingPathComponent("Resources", isDirectory: true)
        if fm.fileExists(atPath: resources.appendingPathComponent("manifest.json").path) {
            return resources
        }
        return directory
    }

    private func prepared(from staging: URL, source: InstalledExtension.Source) throws
        -> PreparedExtension
    {
        // `copyDirectory` copies the source *into* the staging path, so the
        // real package root may be one level down.
        let packageRoot = Self.locateManifest(under: staging) ?? staging
        let manifestURL = packageRoot.appendingPathComponent("manifest.json")
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw ExtensionArchive.ArchiveError.missingManifest
        }
        let manifest: ExtensionManifest
        do {
            manifest = try ExtensionManifest.parse(data)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        let report = ExtensionCompatibility.scan(
            manifest: manifest,
            javascriptFiles: ExtensionCompatibility.javascript(in: packageRoot))
        var record = InstalledExtension(manifest: manifest, source: source, report: report)
        let existing = self.record(id: record.id)
        if let existing { record.adoptDecisions(from: existing) }
        return PreparedExtension(
            record: record, manifest: manifest, stagingRoot: staging, packageURL: packageRoot,
            replacing: existing)
    }

    /// Where `manifest.json` ended up: at the staging root, or exactly one
    /// directory below it (which is what a directory copy produces).
    private static func locateManifest(under staging: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.appendingPathComponent("manifest.json").path) {
            return staging
        }
        let children =
            (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        for child in children
        where fm.fileExists(atPath: child.appendingPathComponent("manifest.json").path) {
            return child
        }
        return nil
    }

    private func freshStagingDirectory() throws -> URL {
        let url = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Cancelled install: the staged bytes go away entirely.
    func discard(_ prepared: PreparedExtension) {
        try? FileManager.default.removeItem(at: prepared.stagingRoot)
    }

    /// Throw away every staging directory. Called at launch, because a crash
    /// between `prepare` and `commit` leaves one behind and nothing else ever
    /// looks at them again.
    func clearStaging() {
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    // MARK: Committing

    /// Move the staged package into place and record the owner's decisions.
    @discardableResult
    func commit(
        _ prepared: PreparedExtension,
        grantedPermissions: Set<String>,
        grantedHostPatterns: Set<String>
    ) throws -> InstalledExtension {
        let fm = FileManager.default
        let destination = directory(for: prepared.record.id)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: prepared.packageURL, to: destination)
        discard(prepared)

        var record = prepared.record
        let requestable = Set(record.requestedPermissions + record.optionalPermissions)
        record.grantedPermissions = grantedPermissions.intersection(requestable).sorted()
        record.deniedPermissions = requestable.subtracting(grantedPermissions).sorted()
        let patterns = Set(record.requestedHostPatterns + record.optionalHostPatterns)
        record.grantedHostPatterns = grantedHostPatterns.intersection(patterns).sorted()
        record.deniedHostPatterns = patterns.subtracting(grantedHostPatterns).sorted()
        record.updatedAt = Date()

        upsert(record)
        return record
    }

    private func upsert(_ record: InstalledExtension) {
        if let index = extensions.firstIndex(where: { $0.id == record.id }) {
            extensions[index] = record
        } else {
            extensions.append(record)
        }
        extensions.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
    }

    // MARK: Editing

    func remove(_ id: String) {
        extensions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: directory(for: id))
        persist()
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        update(id) { $0.isEnabled = enabled }
    }

    func setPermission(_ permission: String, granted: Bool?, for id: String) {
        update(id) { record in
            record.grantedPermissions.removeAll { $0 == permission }
            record.deniedPermissions.removeAll { $0 == permission }
            switch granted {
            case .some(true): record.grantedPermissions.append(permission)
            case .some(false): record.deniedPermissions.append(permission)
            case .none: break
            }
            record.grantedPermissions.sort()
            record.deniedPermissions.sort()
        }
    }

    func setHostPattern(_ pattern: String, granted: Bool?, for id: String) {
        update(id) { record in
            record.grantedHostPatterns.removeAll { $0 == pattern }
            record.deniedHostPatterns.removeAll { $0 == pattern }
            switch granted {
            case .some(true): record.grantedHostPatterns.append(pattern)
            case .some(false): record.deniedHostPatterns.append(pattern)
            case .none: break
            }
            record.grantedHostPatterns.sort()
            record.deniedHostPatterns.sort()
        }
    }

    /// The "on this site" control. `nil` clears the override and falls back to
    /// whatever the granted patterns say.
    func setSiteAccess(_ access: InstalledExtension.SiteAccess?, host: String, for id: String) {
        let key = host.lowercased()
        guard !key.isEmpty else { return }
        update(id) { $0.siteAccess[key] = access }
    }

    func siteAccess(for host: String, in id: String) -> InstalledExtension.SiteAccess? {
        record(id: id)?.siteAccess[host.lowercased()]
    }

    private func update(_ id: String, _ mutate: (inout InstalledExtension) -> Void) {
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return }
        var record = extensions[index]
        mutate(&record)
        guard record != extensions[index] else { return }
        extensions[index] = record
        persist()
    }

    private func persist() {
        file.save(extensions)
    }

    // MARK: The app's own fixtures

    /// The two extensions shipped inside the app, used as a smoke test: one
    /// injects a badge through a content script, one blocks a request through
    /// `declarativeNetRequest`. They are the same directories the unit tests
    /// load — there is exactly one copy of each in the repository, referenced
    /// by both targets, so a fixture that passes the tests is the fixture that
    /// gets installed.
    static let bundledFixtureNames = ["zen-badge", "zen-blocker"]

    static func bundledFixtureURL(_ name: String, bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: nil), url.hasDirectoryPath {
            return url
        }
        let guess = bundle.bundleURL.appendingPathComponent(name, isDirectory: true)
        return FileManager.default.fileExists(
            atPath: guess.appendingPathComponent("manifest.json").path) ? guess : nil
    }

    /// Prepare every bundled fixture that is not already installed at the same
    /// version. Returns them in declaration order.
    ///
    /// The already-installed filter matters more than it looks: the button is
    /// "install the test extensions", and offering an install sheet for one
    /// that is already there — identical version, identical package — is a
    /// question with no useful answer. It also means tapping the button twice
    /// finishes the job when the first pass only got through one.
    func prepareBundledFixtures(bundle: Bundle = .main) -> [PreparedExtension] {
        Self.bundledFixtureNames.compactMap { name in
            guard let url = Self.bundledFixtureURL(name, bundle: bundle) else { return nil }
            guard let prepared = try? prepare(directory: url, source: .bundled(name: name))
            else { return nil }
            guard record(id: prepared.record.id)?.version != prepared.record.version else {
                discard(prepared)
                return nil
            }
            return prepared
        }
    }
}
