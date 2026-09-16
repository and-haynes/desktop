//  ExtensionInbox.swift
//  A package another app handed us (#008B8).
//
//  `Info.plist` declares the XPI and CRX types, which is what puts Zen in the
//  Share sheet and in Files' "Open With" for an extension downloaded in Safari.
//  Declaring the types is only half of it: the system then hands the app a file
//  URL through `onOpenURL`, and an app that does not answer that shows up in
//  the sheet, is chosen, launches, and does nothing — which is worse than not
//  appearing at all.
//
//  Two details that are easy to get wrong:
//
//   * **It is a copy, and nothing else deletes it.** With
//     `LSSupportsOpeningDocumentsInPlace` false — which is right, Zen unpacks
//     its own copy and never edits what it was given — the system copies the
//     file into `Documents/Inbox` first. Left alone, every extension anybody
//     ever shared stays there taking up space forever.
//   * **It may be security-scoped.** A URL that arrived by other routes needs
//     the access bracket before it can be read, and reading without it fails
//     with "no such file" on a path that plainly exists.

import Foundation

enum ExtensionInbox {

    enum InboxError: LocalizedError, Equatable {
        case notAnExtension(String)

        var errorDescription: String? {
            switch self {
            case .notAnExtension(let name):
                return
                    "\(name) is not a browser extension. Zen installs an .xpi (Firefox), a "
                    + ".crx or .zip (Chrome), or a folder with a manifest.json in it."
            }
        }
    }

    /// The file types `Info.plist` claims, lowercased.
    static let packageFileExtensions: Set<String> = ["xpi", "crx", "zip"]

    /// Something worth opening the install sheet for. A directory qualifies on
    /// its contents rather than its name, because a Safari web extension's
    /// resource bundle is a `.appex` and an unpacked one has no suffix at all.
    static func isPackage(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if isDirectory(url) {
            let root = ExtensionStore.resolvePackageRoot(url)
            return FileManager.default.fileExists(
                atPath: root.appendingPathComponent("manifest.json").path)
        }
        return packageFileExtensions.contains(url.pathExtension.lowercased())
    }

    /// The system's drop box for documents opened from another app. Only files
    /// under it are ours to delete — a URL the owner picked in Files points at
    /// their own document and must be left exactly where it is.
    static func isInboxCopy(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let inbox = inboxDirectory.standardizedFileURL.path
        guard !inbox.isEmpty else { return false }
        return url.standardizedFileURL.path.hasPrefix(inbox + "/")
    }

    static var inboxDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return (documents.first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Delete the system's copy, if that is what this is.
    static func discardInboxCopy(_ url: URL) {
        guard isInboxCopy(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Everything still sitting in `Documents/Inbox`, oldest first. Run at
    /// launch: a crash between the hand-over and the install leaves a copy
    /// behind, and nothing in the system ever comes back for it.
    static func strandedInboxCopies() -> [URL] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: inboxDirectory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return entries.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left < right
        }
    }

    static func clearInbox() {
        for url in strandedInboxCopies() { try? FileManager.default.removeItem(at: url) }
    }

    /// Read what we were handed and stage it, ready for the install sheet.
    ///
    /// Nothing is installed here: as everywhere else in this feature, the
    /// package is unpacked into staging and scanned so the sheet can say what
    /// it wants and what WebKit will ignore before anybody agrees to it.
    @MainActor
    static func prepare(_ url: URL, in store: ExtensionStore) throws -> PreparedExtension {
        let name = url.lastPathComponent
        // First, so that it runs last — and before the guard, because a file
        // Zen refuses is still a copy only Zen can delete. Deferring it after
        // the guard is how `Documents/Inbox` fills up with other people's PDFs.
        defer { discardInboxCopy(url) }

        // The access bracket goes around the `isPackage` check too: deciding
        // what a security-scoped URL is means reading it, and reading one
        // outside the bracket fails as "no such file" on a path that plainly
        // exists — which would read here as "that is not an extension".
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard isPackage(url) else { throw InboxError.notAnExtension(name) }

        if isDirectory(url) {
            return try store.prepare(directory: url, source: .file(name: name))
        }
        return try store.prepare(archive: try Data(contentsOf: url), source: .file(name: name))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        return exists && directory.boolValue
    }
}
