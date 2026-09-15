//  ExtensionCompatibilityTests.swift
//  That the report tells the truth about the two fixtures: one clean, one
//  built out of everything WebKit does not have.
//
//  The thing being pinned is the *shape* of the answer — clean packages must
//  produce no scary rows, and a Firefox-shaped blocker must be called out on
//  `webRequestBlocking` specifically, because that single permission is the
//  difference between "uBlock Origin works here" and "uBlock Origin installs
//  and silently blocks nothing".

import XCTest

@testable import Zen

final class ExtensionCompatibilityTests: XCTestCase {

    // MARK: The clean fixtures

    func testACleanMV3ExtensionReportsNothingBlocking() throws {
        let report = try scan("zen-badge")
        XCTAssertTrue(report.isLoadable)
        XCTAssertEqual(
            report.findings, [],
            "zen-badge uses storage, runtime, action and content scripts — all supported")
        XCTAssertEqual(report.summary, "No unsupported APIs found")
    }

    func testTheDeclarativeNetRequestFixtureIsClean() throws {
        let report = try scan("zen-blocker")
        XCTAssertTrue(report.isLoadable)
        XCTAssertEqual(report.findings, [])
        XCTAssertTrue(report.detectedNamespaces.contains("declarativeNetRequest"))
        XCTAssertTrue(report.detectedNamespaces.contains("action"))
    }

    func testTheScanActuallyReadsTheScripts() throws {
        let report = try scan("zen-badge")
        XCTAssertGreaterThanOrEqual(report.scannedFileCount, 4)
        XCTAssertTrue(report.detectedNamespaces.contains("storage"))
        XCTAssertTrue(report.detectedNamespaces.contains("runtime"))
    }

    // MARK: The Firefox-shaped one

    func testBlockingWebRequestIsReportedAsFatal() throws {
        let report = try scan("unsupported-blocker")
        XCTAssertFalse(report.isLoadable)
        let finding = try XCTUnwrap(report.findings.first { $0.subject == "webRequestBlocking" })
        XCTAssertEqual(finding.severity, .blocking)
        XCTAssertEqual(finding.kind, .permission)
        XCTAssertTrue(finding.detail.contains("declarativeNetRequest"))
    }

    func testAPersistentBackgroundPageIsReportedAsFatal() throws {
        let report = try scan("unsupported-blocker")
        let finding = try XCTUnwrap(
            report.findings.first { $0.subject == "persistent background page" })
        XCTAssertEqual(finding.severity, .blocking)
        XCTAssertEqual(finding.kind, .background)
    }

    func testTheSidebarIsReportedFromBothTheManifestAndTheScripts() throws {
        let report = try scan("unsupported-blocker")
        // The manifest key and the API share one subject line after
        // deduplication; what matters is that it is called out at all, and as
        // fatal, since this extension has no toolbar action to fall back on.
        let sidebar = report.findings.filter {
            $0.subject == "sidebar_action" || $0.subject == "sidebarAction"
        }
        XCTAssertFalse(sidebar.isEmpty)
        XCTAssertTrue(sidebar.contains { $0.severity == .blocking })
    }

    func testContainersAndBrowsingDataAreReportedFromTheScripts() throws {
        let report = try scan("unsupported-blocker")
        let containers = try XCTUnwrap(
            report.findings.first { $0.subject == "contextualIdentities" })
        XCTAssertTrue(containers.detail.contains("space"), containers.detail)
        XCTAssertNotNil(report.findings.first { $0.subject == "browsingData" })
    }

    func testAFindingNamesTheFileItWasSeenIn() throws {
        let report = try scan("unsupported-blocker")
        let finding = try XCTUnwrap(report.findings.first { $0.kind == .api })
        XCTAssertFalse(finding.locations.isEmpty)
        XCTAssertTrue(
            finding.locations.allSatisfy { $0.hasSuffix(".js") },
            "locations are file paths inside the package")
    }

    func testManifestVersion2IsANoteAndNotAFailure() throws {
        let report = try scan("unsupported-blocker")
        let note = try XCTUnwrap(report.findings.first { $0.kind == .manifestVersion })
        XCTAssertEqual(note.severity, .note)
    }

    func testTheSummaryLeadsWithWhatIsFatal() throws {
        let report = try scan("unsupported-blocker")
        XCTAssertTrue(report.summary.contains("depends on"), report.summary)
        XCTAssertGreaterThan(report.blockingCount, 0)
    }

    // MARK: The scanner itself

    func testANamespaceOnAnUnrelatedObjectIsNotAMatch() {
        let result = ExtensionCompatibility.scanNamespaces(in: [
            "a.js": "myBrowser.sidebarAction.open(); window.chrome_sidebarAction();"
        ])
        XCTAssertTrue(
            result.namespaces.isEmpty,
            "`myBrowser.` is not `browser.` — a left word boundary is the whole point")
    }

    func testWhitespaceAroundTheDotIsStillAMatch() {
        let result = ExtensionCompatibility.scanNamespaces(in: [
            "a.js": "browser . sidebarAction.open();"
        ])
        XCTAssertEqual(result.namespaces, ["sidebarAction"])
    }

    func testASupportedNamespaceProducesNoFinding() {
        let result = ExtensionCompatibility.scanNamespaces(in: [
            "a.js": "chrome.tabs.query({}); chrome.storage.local.get(); browser.runtime.id;"
        ])
        XCTAssertEqual(result.findings, [])
        XCTAssertEqual(result.namespaces, ["tabs", "storage", "runtime"])
    }

    func testAnUnknownNamespaceIsStillReported() {
        let result = ExtensionCompatibility.scanNamespaces(in: [
            "a.js": "browser.somethingInvented.doThing();"
        ])
        let finding = try? XCTUnwrap(result.findings.first)
        XCTAssertEqual(finding?.subject, "somethingInvented")
        XCTAssertEqual(finding?.severity, .degraded)
    }

    func testABlockingWebRequestListenerIsFoundWithoutThePermission() throws {
        // Chrome MV2 extensions ask for `webRequestBlocking`; a few only pass
        // "blocking" at the call site. Both have to be caught.
        let manifest = try ExtensionManifest.parse(
            Data(
                #"{"manifest_version": 2, "name": "A", "version": "1", "permissions": ["webRequest"]}"#
                    .utf8))
        let report = ExtensionCompatibility.scan(
            manifest: manifest,
            javascriptFiles: [
                "bg.js": "browser.webRequest.onBeforeRequest.addListener(f, {}, [\"blocking\"]);"
            ])
        let finding = try XCTUnwrap(
            report.findings.first { $0.subject == "webRequest (blocking)" })
        XCTAssertEqual(finding.severity, .degraded)
        XCTAssertEqual(finding.locations, ["bg.js"])
    }

    func testTheSupportedPermissionListMatchesWebKitsOwnVocabulary() {
        // Transcribed from `WKWebExtensionPermission.h`. If WebKit gains one,
        // this is the line that has to change, and the report stops lying.
        XCTAssertEqual(
            ExtensionCompatibility.supportedPermissions,
            [
                "activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies",
                "declarativeNetRequest", "declarativeNetRequestFeedback",
                "declarativeNetRequestWithHostAccess", "menus", "nativeMessaging", "scripting",
                "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest",
            ])
        XCTAssertFalse(
            ExtensionCompatibility.supportedPermissions.contains("webRequestBlocking"),
            "the blocking variant is exactly the one WebKit does not have")
    }

    // MARK: Plumbing

    private func scan(_ name: String) throws -> ExtensionCompatibilityReport {
        let directory = try ExtensionFixtures.directory(name)
        let manifest = try ExtensionFixtures.manifest(name)
        return ExtensionCompatibility.scan(
            manifest: manifest,
            javascriptFiles: ExtensionCompatibility.javascript(in: directory))
    }
}
