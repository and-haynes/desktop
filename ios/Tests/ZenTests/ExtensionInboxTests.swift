//  ExtensionInboxTests.swift
//  The Share sheet route, which is the one nobody can test by hand twice.
//
//  Handing a file to an app from outside it is several seconds of tapping in
//  Safari, and the interesting cases — a file that is not an extension, a copy
//  left behind in `Documents/Inbox`, a folder that is a Safari web extension's
//  resource bundle — are exactly the ones nobody repeats. So they live here.

import XCTest

@testable import Zen

@MainActor
final class ExtensionInboxTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = ExtensionFixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        ExtensionFixtures.cleanUp(scratch)
        ExtensionInbox.clearInbox()
    }

    private func makeStore() -> ExtensionStore {
        ExtensionStore(
            file: JSONFileStore<[InstalledExtension]>(
                url: scratch.appendingPathComponent("extensions.json")),
            root: scratch.appendingPathComponent("Extensions", isDirectory: true))
    }

    /// Put bytes where the system would have put them: `Documents/Inbox`.
    @discardableResult
    private func placeInInbox(_ data: Data, named name: String) throws -> URL {
        let inbox = ExtensionInbox.inboxDirectory
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let url = inbox.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: What counts as a package

    func testTheDeclaredFileTypesAreRecognised() throws {
        for name in ["ublock.xpi", "darkreader.crx", "something.zip", "SHOUTING.XPI"] {
            let url = scratch.appendingPathComponent(name)
            try Data("not really".utf8).write(to: url)
            XCTAssertTrue(ExtensionInbox.isPackage(url), "\(name) should be offered to the sheet")
        }
    }

    func testAnUnpackedFolderIsRecognisedByItsManifest() throws {
        let directory = try ExtensionFixtures.directory("zen-badge")
        XCTAssertTrue(ExtensionInbox.isPackage(directory))
    }

    /// A Safari web extension's resource bundle keeps `manifest.json` under
    /// `Resources`, and is the one folder shape that arrives with no suffix
    /// worth looking at.
    func testASafariStyleResourceBundleIsRecognised() throws {
        let bundle = scratch.appendingPathComponent("Blocker.appex", isDirectory: true)
        let resources = bundle.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(
            contentsOf: try ExtensionFixtures.directory("zen-badge")
                .appendingPathComponent("manifest.json")
        ).write(to: resources.appendingPathComponent("manifest.json"))
        XCTAssertTrue(ExtensionInbox.isPackage(bundle))
    }

    func testSomethingElseIsNotAPackage() throws {
        let url = scratch.appendingPathComponent("statement.pdf")
        try Data("%PDF-1.4".utf8).write(to: url)
        XCTAssertFalse(ExtensionInbox.isPackage(url))
        XCTAssertFalse(
            ExtensionInbox.isPackage(URL(string: "https://addons.mozilla.org/x")!),
            "a web URL is not a file the Share sheet handed us")
    }

    func testANonPackageIsRefusedWithSomethingWorthReading() throws {
        let url = scratch.appendingPathComponent("statement.pdf")
        try Data("%PDF-1.4".utf8).write(to: url)
        XCTAssertThrowsError(try ExtensionInbox.prepare(url, in: makeStore())) { error in
            XCTAssertEqual(
                error as? ExtensionInbox.InboxError, .notAnExtension("statement.pdf"),
                "the name is in the message because it is the only thing the owner recognises")
            XCTAssertTrue(
                (error as? LocalizedError)?.errorDescription?.contains(".xpi") == true,
                "and it says what would work")
        }
    }

    // MARK: Arriving

    func testAnXPIHandedOverIsStagedAndScannedButNotInstalled() throws {
        let store = makeStore()
        let url = try placeInInbox(
            try ExtensionFixtures.archive("zen-badge.xpi"), named: "zen-badge.xpi")

        let prepared = try ExtensionInbox.prepare(url, in: store)

        XCTAssertEqual(prepared.record.name, "Zen Badge")
        XCTAssertEqual(prepared.record.source, .file(name: "zen-badge.xpi"))
        XCTAssertTrue(
            store.extensions.isEmpty,
            "a file arriving from outside the app is the last place to install before asking")
        XCTAssertTrue(
            prepared.record.grantedPermissions.isEmpty,
            "nothing is granted until the install sheet says so")
    }

    func testACRXHandedOverWorksToo() throws {
        let url = try placeInInbox(
            try ExtensionFixtures.archive("zen-badge.crx"), named: "zen-badge.crx")
        let prepared = try ExtensionInbox.prepare(url, in: makeStore())
        XCTAssertEqual(prepared.record.id, "zen-badge-morton.lan")
    }

    /// `LSSupportsOpeningDocumentsInPlace` is false, so the system copies the
    /// file into `Documents/Inbox` before handing it over — and nothing in the
    /// system ever deletes it again.
    func testTheSystemsCopyIsDeletedOnceItHasBeenRead() throws {
        let url = try placeInInbox(
            try ExtensionFixtures.archive("zen-badge.xpi"), named: "zen-badge.xpi")
        _ = try ExtensionInbox.prepare(url, in: makeStore())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "the inbox copy outlived the install it was for")
    }

    func testARefusedFileIsAlsoCleanedUp() throws {
        let url = try placeInInbox(Data("%PDF-1.4".utf8), named: "statement.pdf")
        XCTAssertThrowsError(try ExtensionInbox.prepare(url, in: makeStore()))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "a file Zen refused is still a file only Zen can delete")
    }

    /// The owner's own document, picked in Files, is not ours to remove.
    func testAFilePickedFromFilesIsLeftWhereItIs() throws {
        let url = scratch.appendingPathComponent("zen-badge.xpi")
        try ExtensionFixtures.archive("zen-badge.xpi").write(to: url)
        XCTAssertFalse(ExtensionInbox.isInboxCopy(url))
        _ = try ExtensionInbox.prepare(url, in: makeStore())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Zen deleted a file out of somebody's own documents")
    }

    /// A crash between the hand-over and the install leaves the copy behind.
    func testStrandedCopiesAreFoundAndCleared() throws {
        try placeInInbox(Data("one".utf8), named: "stranded-one.xpi")
        try placeInInbox(Data("two".utf8), named: "stranded-two.crx")
        XCTAssertEqual(ExtensionInbox.strandedInboxCopies().count, 2)
        ExtensionInbox.clearInbox()
        XCTAssertTrue(ExtensionInbox.strandedInboxCopies().isEmpty)
    }
}
