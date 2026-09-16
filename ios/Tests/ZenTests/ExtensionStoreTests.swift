//  ExtensionStoreTests.swift
//  Installing, persisting, editing and removing — without WebKit.
//
//  The store is deliberately free of `WKWebExtension`, so all of this runs on
//  any simulator and the installed list survives on a device that cannot load
//  extensions at all. That is the property being pinned here as much as the
//  behaviour: someone who installs an extension and then downgrades below
//  iOS 18.4 must still be able to see it and remove it.

import XCTest

@testable import Zen

@MainActor
final class ExtensionStoreTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = ExtensionFixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        ExtensionFixtures.cleanUp(scratch)
    }

    /// `allowsBundledFixtures` defaults to what a shipped app sees — no test
    /// argument — so the eviction (#008DB) is the behaviour under test here,
    /// not something the test runner's own launch arguments decide.
    private func makeStore(allowsBundledFixtures: Bool = false) -> ExtensionStore {
        ExtensionStore(
            file: JSONFileStore<[InstalledExtension]>(
                url: scratch.appendingPathComponent("extensions.json")),
            root: scratch.appendingPathComponent("Extensions", isDirectory: true),
            allowsBundledFixtures: allowsBundledFixtures)
    }

    // MARK: Preparing

    func testPreparingAnXPIReadsItWithoutInstallingIt() throws {
        let store = makeStore()
        let prepared = try store.prepare(
            archive: try ExtensionFixtures.archive("zen-badge.xpi"),
            source: .file(name: "zen-badge.xpi"))
        XCTAssertEqual(prepared.record.name, "Zen Badge")
        XCTAssertEqual(prepared.record.id, "zen-badge-morton.lan")
        XCTAssertTrue(prepared.record.hasAction)
        XCTAssertTrue(prepared.record.hasOptionsPage)
        XCTAssertTrue(prepared.record.hasContentScripts)
        XCTAssertTrue(
            store.extensions.isEmpty, "preparing must not add anything to the installed list")
        XCTAssertFalse(prepared.isUpdate)
    }

    func testPreparingACRXWorksToo() throws {
        let store = makeStore()
        let prepared = try store.prepare(
            archive: try ExtensionFixtures.archive("zen-badge.crx"),
            source: .file(name: "zen-badge.crx"))
        XCTAssertEqual(prepared.record.name, "Zen Badge")
    }

    func testPreparingADirectoryWorks() throws {
        let store = makeStore()
        let prepared = try store.prepare(
            directory: try ExtensionFixtures.directory("zen-blocker"),
            source: .bundled(name: "zen-blocker"))
        XCTAssertEqual(prepared.record.name, "Zen Blocker")
        XCTAssertTrue(prepared.record.hasDeclarativeNetRequest)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: prepared.packageURL.appendingPathComponent("rules.json").path))
    }

    func testCancellingAnInstallLeavesNothingBehind() throws {
        let store = makeStore()
        let prepared = try store.prepare(
            archive: try ExtensionFixtures.archive("zen-badge.xpi"),
            source: .file(name: "zen-badge.xpi"))
        store.discard(prepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.stagingRoot.path))
        XCTAssertTrue(store.extensions.isEmpty)
    }

    func testANonPackageIsRefusedWithSomethingSayable() {
        let store = makeStore()
        XCTAssertThrowsError(
            try store.prepare(
                archive: Data("this is a PDF, honestly".utf8), source: .file(name: "x.pdf"))
        ) { error in
            XCTAssertEqual(error as? ExtensionArchive.ArchiveError, .notAnArchive)
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
    }

    // MARK: Committing

    func testCommittingInstallsAndRecordsTheGrants() throws {
        let store = makeStore()
        let prepared = try store.prepare(
            archive: try ExtensionFixtures.archive("zen-badge.xpi"),
            source: .file(name: "zen-badge.xpi"))
        let record = try store.commit(
            prepared, grantedPermissions: ["storage"], grantedHostPatterns: [])

        XCTAssertEqual(store.extensions.count, 1)
        XCTAssertEqual(record.grantedPermissions, ["storage"])
        XCTAssertEqual(
            record.deniedPermissions, ["activeTab"],
            "a requested permission that was not granted is denied, not merely absent")
        XCTAssertEqual(record.deniedHostPatterns, ["<all_urls>"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.directory(for: record.id).appendingPathComponent("content.js").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: prepared.stagingRoot.path),
            "the staging directory is consumed by the install")
    }

    func testTheInstalledListSurvivesARelaunch() throws {
        let store = makeStore()
        let prepared = try store.prepare(
            archive: try ExtensionFixtures.archive("zen-badge.xpi"),
            source: .file(name: "zen-badge.xpi"))
        _ = try store.commit(
            prepared, grantedPermissions: ["storage", "activeTab"],
            grantedHostPatterns: ["<all_urls>"])

        let reopened = makeStore()
        XCTAssertEqual(reopened.extensions.count, 1)
        let record = try XCTUnwrap(reopened.extensions.first)
        XCTAssertEqual(record.name, "Zen Badge")
        XCTAssertEqual(record.grantedHostPatterns, ["<all_urls>"])
        XCTAssertEqual(record.hostAccessSummary, "All sites")
        XCTAssertEqual(record.compatibility.findings, [])
    }

    func testARecordWhoseFilesAreGoneIsDroppedAtLaunch() throws {
        let store = makeStore()
        let prepared = try store.prepare(
            archive: try ExtensionFixtures.archive("zen-badge.xpi"),
            source: .file(name: "zen-badge.xpi"))
        let record = try store.commit(
            prepared, grantedPermissions: [], grantedHostPatterns: [])
        try FileManager.default.removeItem(at: store.directory(for: record.id))

        XCTAssertTrue(
            makeStore().extensions.isEmpty,
            "a row that can only ever fail to load is worse than no row")
    }

    func testReinstallingKeepsTheOwnersDecisions() throws {
        let store = makeStore()
        let first = try store.prepare(
            archive: try ExtensionFixtures.archive("zen-badge.xpi"),
            source: .file(name: "zen-badge.xpi"))
        _ = try store.commit(
            first, grantedPermissions: ["storage"], grantedHostPatterns: ["<all_urls>"])
        store.setEnabled(false, for: "zen-badge-morton.lan")
        store.setSiteAccess(.deny, host: "example.com", for: "zen-badge-morton.lan")

        let again = try store.prepare(
            archive: try ExtensionFixtures.archive("zen-badge.crx"),
            source: .file(name: "zen-badge.crx"))
        XCTAssertTrue(again.isUpdate)
        XCTAssertEqual(again.record.grantedPermissions, ["storage"])
        XCTAssertEqual(again.record.siteAccess["example.com"], .deny)
        XCTAssertFalse(again.record.isEnabled, "an update must not silently re-enable")
        XCTAssertEqual(store.extensions.count, 1, "an update replaces rather than duplicates")
    }

    // MARK: Editing

    func testEnablingAndDisabling() throws {
        let store = try storeWithBadge()
        store.setEnabled(false, for: "zen-badge-morton.lan")
        XCTAssertTrue(store.enabledExtensions.isEmpty)
        XCTAssertEqual(store.extensions.count, 1, "disabling is not removing")
        store.setEnabled(true, for: "zen-badge-morton.lan")
        XCTAssertEqual(store.enabledExtensions.count, 1)
    }

    func testPermissionsAreThreeStateNotTwo() throws {
        let store = try storeWithBadge()
        let id = "zen-badge-morton.lan"
        store.setPermission("activeTab", granted: true, for: id)
        XCTAssertTrue(store.record(id: id)?.grantedPermissions.contains("activeTab") == true)
        XCTAssertFalse(store.record(id: id)?.deniedPermissions.contains("activeTab") == true)

        store.setPermission("activeTab", granted: nil, for: id)
        XCTAssertFalse(store.record(id: id)?.grantedPermissions.contains("activeTab") == true)
        XCTAssertFalse(
            store.record(id: id)?.deniedPermissions.contains("activeTab") == true,
            "unset means WebKit may ask; it is not the same as a refusal")
    }

    func testPerSiteAccessIsCaseInsensitiveAndClearable() throws {
        let store = try storeWithBadge()
        let id = "zen-badge-morton.lan"
        store.setSiteAccess(.allow, host: "Example.COM", for: id)
        XCTAssertEqual(store.siteAccess(for: "example.com", in: id), .allow)
        store.setSiteAccess(nil, host: "example.com", for: id)
        XCTAssertNil(store.siteAccess(for: "example.com", in: id))
    }

    func testRemovingTakesTheFilesWithIt() throws {
        let store = try storeWithBadge()
        let directory = store.directory(for: "zen-badge-morton.lan")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        store.remove("zen-badge-morton.lan")
        XCTAssertTrue(store.extensions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(makeStore().extensions.isEmpty)
    }

    // MARK: Host summaries

    func testHostAccessSummaryReadsLikeSomethingAPersonWouldSay() {
        var record = InstalledExtension(
            manifest: try! ExtensionManifest.parse(
                Data(#"{"manifest_version":3,"name":"A","version":"1"}"#.utf8)),
            source: .file(name: "a.xpi"), report: .init())
        XCTAssertEqual(record.hostAccessSummary, "No site access")
        record.grantedHostPatterns = ["*://*.example.com/*"]
        XCTAssertEqual(record.hostAccessSummary, "example.com")
        record.grantedHostPatterns = ["*://*.example.com/*", "https://other.test/*"]
        XCTAssertEqual(record.hostAccessSummary, "2 sites")
        record.grantedHostPatterns = ["<all_urls>"]
        XCTAssertEqual(record.hostAccessSummary, "All sites")
    }

    func testTheSingleSitePatternRoundTrips() {
        let pattern = InstalledExtension.pattern(forHost: "news.example.com")
        XCTAssertEqual(pattern, "*://news.example.com/*")
        XCTAssertEqual(InstalledExtension.hostLabel(pattern), "news.example.com")
        XCTAssertNil(InstalledExtension.hostLabel("<all_urls>"))
    }

    // MARK: The test fixtures (#008DB)

    /// The migration for a phone that installed the fixtures from the
    /// Settings button that used to offer them: a store that is not under
    /// test evicts them at load, package and all, so the banner stops at the
    /// next launch without anyone having to find where it came from.
    func testAStoreNotUnderTestEvictsTheBundledFixtures() throws {
        let underTest = makeStore(allowsBundledFixtures: true)
        let prepared = try underTest.prepare(
            directory: try ExtensionFixtures.directory("zen-badge"),
            source: .bundled(name: "zen-badge"))
        let record = try underTest.commit(
            prepared, grantedPermissions: [], grantedHostPatterns: [])
        XCTAssertEqual(
            makeStore(allowsBundledFixtures: true).extensions.map(\.id), [record.id],
            "under test the fixture survives a reload")

        let shipped = makeStore()
        XCTAssertTrue(shipped.extensions.isEmpty, "outside the test runner the fixture is evicted")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: shipped.directory(for: record.id).path),
            "eviction removes the package, not just the row")
        XCTAssertTrue(
            makeStore(allowsBundledFixtures: true).extensions.isEmpty,
            "eviction is written back, not just filtered in memory")
    }

    /// Only the fixtures go. The same package installed from a file is
    /// something the person chose, and it stays.
    func testEvictionLeavesOrdinaryInstallsAlone() throws {
        _ = try storeWithBadge()
        XCTAssertEqual(makeStore().extensions.count, 1)
    }

    // MARK: Plumbing

    private func storeWithBadge() throws -> ExtensionStore {
        let store = makeStore()
        let prepared = try store.prepare(
            archive: try ExtensionFixtures.archive("zen-badge.xpi"),
            source: .file(name: "zen-badge.xpi"))
        _ = try store.commit(prepared, grantedPermissions: ["storage"], grantedHostPatterns: [])
        return store
    }
}
