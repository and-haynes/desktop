//  ExtensionManifestTests.swift
//  That we read a manifest the way the install sheet needs to present it.
//
//  The interesting cases are all about MV2 and MV3 disagreeing: MV2 mixes host
//  patterns into `permissions`, MV3 splits them out; MV2 calls the toolbar
//  button `browser_action`, MV3 calls it `action`; MV2 has a persistent
//  background page, which iOS refuses outright.

import XCTest

@testable import Zen

final class ExtensionManifestTests: XCTestCase {

    // MARK: MV3

    func testAnMV3ManifestParses() throws {
        let manifest = try ExtensionFixtures.manifest("zen-badge")
        XCTAssertEqual(manifest.manifestVersion, 3)
        XCTAssertEqual(manifest.name, "Zen Badge")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.permissions, ["storage", "activeTab"])
        XCTAssertEqual(manifest.hostPermissions, ["<all_urls>"])
        XCTAssertEqual(manifest.action?.key, "action")
        XCTAssertEqual(manifest.action?.defaultPopup, "popup.html")
        XCTAssertEqual(manifest.optionsPage, "options.html")
        XCTAssertEqual(manifest.backgroundScripts, ["background.js"])
        XCTAssertTrue(manifest.backgroundIsServiceWorker)
        XCTAssertFalse(
            manifest.backgroundIsPersistent,
            "a service worker is never persistent, and iOS rejects persistence")
        XCTAssertEqual(manifest.contentScripts.count, 1)
        XCTAssertEqual(manifest.contentScripts.first?.js, ["content.js"])
        XCTAssertEqual(manifest.contentScripts.first?.runAt, "document_end")
        XCTAssertEqual(manifest.geckoID, "zen-badge@morton.lan")
    }

    func testDeclarativeNetRequestRulesetsAreRead() throws {
        let manifest = try ExtensionFixtures.manifest("zen-blocker")
        XCTAssertEqual(manifest.declarativeNetRequestRulesets.count, 1)
        let ruleset = try XCTUnwrap(manifest.declarativeNetRequestRulesets.first)
        XCTAssertEqual(ruleset.id, "zen-rules")
        XCTAssertEqual(ruleset.path, "rules.json")
        XCTAssertTrue(ruleset.enabled)
    }

    // MARK: MV2

    func testAnMV2ManifestSplitsHostPatternsOutOfPermissions() throws {
        let manifest = try ExtensionFixtures.manifest("unsupported-blocker")
        XCTAssertEqual(manifest.manifestVersion, 2)
        XCTAssertFalse(
            manifest.permissions.contains("<all_urls>"),
            "`<all_urls>` is a host pattern, not an API permission")
        XCTAssertEqual(manifest.hostPermissions, ["<all_urls>"])
        XCTAssertTrue(manifest.permissions.contains("webRequestBlocking"))
        XCTAssertTrue(manifest.permissions.contains("contextualIdentities"))
    }

    func testAPersistentMV2BackgroundIsRecognised() throws {
        let manifest = try ExtensionFixtures.manifest("unsupported-blocker")
        XCTAssertEqual(manifest.backgroundScripts, ["background.js"])
        XCTAssertTrue(manifest.backgroundIsPersistent)
        XCTAssertFalse(manifest.backgroundIsServiceWorker)
    }

    func testTheGeckoBlockIsReadFromEitherKey() throws {
        // `applications` is the old spelling; the fixture uses it deliberately.
        let manifest = try ExtensionFixtures.manifest("unsupported-blocker")
        XCTAssertEqual(manifest.geckoID, "legacy-blocker@example.invalid")
        XCTAssertEqual(manifest.geckoStrictMinVersion, "91.0")
    }

    func testAnMV2BrowserActionIsFoundUnderItsOwnKey() throws {
        let manifest = try parse(
            """
            {"manifest_version": 2, "name": "A", "version": "1",
             "browser_action": {"default_title": "A", "default_popup": "p.html",
                                "default_icon": {"48": "i48.png", "16": "i16.png"}}}
            """)
        XCTAssertEqual(manifest.action?.key, "browser_action")
        XCTAssertEqual(manifest.action?.defaultPopup, "p.html")
        XCTAssertEqual(manifest.action?.defaultIcons.bestPath, "i48.png")
    }

    // MARK: Identity

    func testTheIdentifierPrefersTheGeckoIDAndIsFilesystemSafe() throws {
        let manifest = try ExtensionFixtures.manifest("zen-badge")
        XCTAssertEqual(manifest.identifier, "zen-badge-morton.lan")
        XCTAssertFalse(manifest.identifier.contains("/"))
        XCTAssertFalse(manifest.identifier.contains("@"))
    }

    func testAPackageWithNoGeckoIDFallsBackToItsName() throws {
        let manifest = try parse(
            #"{"manifest_version": 3, "name": "uBlock Origin Lite", "version": "2.1"}"#)
        XCTAssertEqual(manifest.identifier, "ublock-origin-lite")
    }

    func testTheSlugNeverEscapesItsDirectory() {
        XCTAssertEqual(ExtensionManifest.slug("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(ExtensionManifest.slug(".."), "extension")
        XCTAssertEqual(ExtensionManifest.slug("."), "extension")
        XCTAssertEqual(ExtensionManifest.slug("////"), "extension")
        XCTAssertEqual(ExtensionManifest.slug(""), "extension")
        // A dot in the middle is how every Firefox id reads, and stays.
        XCTAssertEqual(
            ExtensionManifest.slug("uBlock0@raymondhill.net"), "ublock0-raymondhill.net")
    }

    func testAManifestCannotNameADirectoryOutsideTheExtensionsFolder() throws {
        let manifest = try parse(
            #"{"manifest_version": 3, "name": "../../../Library/Preferences", "version": "1"}"#)
        XCTAssertFalse(manifest.identifier.contains(".."))
        XCTAssertFalse(manifest.identifier.contains("/"))
        XCTAssertFalse(manifest.identifier.hasPrefix("."))
    }

    // MARK: Tolerance
    //
    // A manifest in the wild is whatever a bundler emitted, and refusing to
    // show somebody what they are installing over a type mismatch would be
    // stricter than WebKit, which is the thing that actually has to load it.

    func testAStringManifestVersionIsAccepted() throws {
        let manifest = try parse(#"{"manifest_version": "3", "name": "A", "version": "1"}"#)
        XCTAssertEqual(manifest.manifestVersion, 3)
    }

    func testAnMSGPlaceholderNameIsMadeReadable() throws {
        let manifest = try parse(
            #"{"manifest_version": 3, "name": "__MSG_extension_name__", "version": "1"}"#)
        XCTAssertEqual(manifest.name, "extension name")
    }

    /// A *description* that is only a placeholder is dropped rather than
    /// de-underscored: "extension description" under the real icon and the
    /// real version number reads like a bug, which is what Dark Reader 4.9.131
    /// looked like before this.
    func testAnMSGPlaceholderDescriptionIsDroppedRatherThanShown() throws {
        let manifest = try parse(
            """
            {"manifest_version": 2, "name": "Dark Reader", "version": "4.9.131",
             "description": "__MSG_description__"}
            """)
        XCTAssertNil(manifest.descriptionText)
        XCTAssertEqual(manifest.name, "Dark Reader")
    }

    func testABareStringDefaultIconIsAccepted() throws {
        let manifest = try parse(
            #"{"manifest_version": 3, "name": "A", "version": "1", "icons": "icon.png"}"#)
        XCTAssertEqual(manifest.icons.bestPath, "icon.png")
    }

    // MARK: Refusals

    func testARefusedManifestSaysWhy() {
        assertParseError(#"not json at all"#, .notJSON)
        assertParseError(#""a string""#, .notAnObject)
        assertParseError(#"{"name": "A", "version": "1"}"#, .missingManifestVersion)
        assertParseError(
            #"{"manifest_version": 1, "name": "A", "version": "1"}"#,
            .unsupportedManifestVersion(1))
        assertParseError(#"{"manifest_version": 3, "version": "1"}"#, .missingName)
        assertParseError(#"{"manifest_version": 3, "name": "A"}"#, .missingVersion)
    }

    // MARK: Host-pattern classification

    func testHostPatternsAreToldApartFromPermissions() {
        for pattern in ["<all_urls>", "*://*/*", "https://example.com/*", "file:///*"] {
            XCTAssertTrue(ExtensionManifest.isHostPattern(pattern), pattern)
        }
        for permission in ["storage", "tabs", "webRequestBlocking", "activeTab"] {
            XCTAssertFalse(ExtensionManifest.isHostPattern(permission), permission)
        }
    }

    // MARK: Plumbing

    private func parse(_ json: String) throws -> ExtensionManifest {
        try ExtensionManifest.parse(Data(json.utf8))
    }

    private func assertParseError(
        _ json: String, _ expected: ExtensionManifest.ParseError,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            _ = try parse(json)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as ExtensionManifest.ParseError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
