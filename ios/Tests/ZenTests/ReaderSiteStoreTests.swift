//  ReaderSiteStoreTests.swift
//  Per-site reader settings: what counts as "this site", and that a choice
//  survives the app being closed (#008BC).

import XCTest

@testable import Zen

@MainActor
final class ReaderSiteStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-sites-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> ReaderSiteStore {
        ReaderSiteStore(
            file: JSONFileStore<[String: ReaderSettings]>(
                name: "reader-sites.json", directory: directory))
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: What counts as one site

    func testSubdomainsOfOneSiteShareAKey() {
        XCTAssertEqual(
            ReaderSite.siteKey(for: url("https://en.wikipedia.org/wiki/Bee")),
            ReaderSite.siteKey(for: url("https://wikipedia.org/")))
        XCTAssertEqual(ReaderSite.siteKey(for: url("https://www.bbc.co.uk/news")), "bbc.co.uk")
    }

    /// Two blogs on one hosting suffix are two sites, not one — reading
    /// preferences that leaked between every GitHub Pages blog would be worse
    /// than none.
    func testSitesUnderAHostingSuffixAreSeparate() {
        XCTAssertEqual(ReaderSite.siteKey(for: url("https://alice.github.io/x")), "alice.github.io")
        XCTAssertEqual(ReaderSite.siteKey(for: url("https://bob.github.io/y")), "bob.github.io")
    }

    /// Filing every address on the LAN under one key would be exactly wrong.
    func testBareHostsAndAddressesAreTheirOwnSite() {
        XCTAssertEqual(ReaderSite.siteKey(for: url("http://10.0.0.42:8092/x")), "10.0.0.42")
        XCTAssertEqual(ReaderSite.siteKey(for: url("http://pi-a/wiki")), "pi-a")
        XCTAssertEqual(ReaderSite.siteKey(for: url("http://refs.lan/page.html")), "refs.lan")
    }

    func testThereIsNothingToRememberAgainstANonWebURL() {
        XCTAssertNil(ReaderSite.siteKey(for: nil))
        XCTAssertNil(ReaderSite.siteKey(for: url("data:text/html,<p>hi</p>")))
        XCTAssertNil(ReaderSite.siteKey(for: url("about:blank")))
        XCTAssertNil(ReaderSite.siteKey(for: url("file:///tmp/x.html")))
    }

    func testTheKeyIsCaseAndTrailingDotInsensitive() {
        XCTAssertEqual(ReaderSite.siteKey(for: url("https://EN.Wikipedia.ORG./x")), "wikipedia.org")
    }

    // MARK: Remembering

    func testASiteWithNoOpinionFollowsTheGlobalDefault() {
        var defaults = ReaderSettings()
        defaults.fontSize = 26
        let subject = store()
        XCTAssertFalse(subject.hasOverride(for: url("https://example.com/a")))
        XCTAssertEqual(
            subject.settings(for: url("https://example.com/a"), default: defaults).fontSize, 26)
    }

    func testAChoiceRoundTripsThroughTheFile() {
        var chosen = ReaderSettings()
        chosen.theme = .sepia
        chosen.font = .charter
        chosen.fontSize = 23
        chosen.dropCaps = true

        let first = store()
        first.set(chosen, for: url("https://en.wikipedia.org/wiki/Bee"))

        // A second store over the same file is the next launch of the app.
        let second = store()
        XCTAssertTrue(second.hasOverride(for: url("https://wikipedia.org/")))
        XCTAssertEqual(
            second.settings(for: url("https://wikipedia.org/"), default: ReaderSettings()), chosen)
    }

    func testOneSitesChoiceDoesNotLeakIntoAnother() {
        var chosen = ReaderSettings()
        chosen.theme = .black
        let subject = store()
        subject.set(chosen, for: url("https://example.com/a"))
        XCTAssertEqual(
            subject.settings(for: url("https://other.com/a"), default: ReaderSettings()).theme,
            ReaderSettings().theme)
    }

    /// A hand-edited file, or one written by a build with a wider range, must
    /// not be able to hand the reader a 4000pt font.
    func testValuesOutOfRangeInTheFileAreClampedOnTheWayOut() {
        var absurd = ReaderSettings()
        absurd.fontSize = 4000
        let subject = store()
        subject.set(absurd, for: url("https://example.com/a"))
        XCTAssertEqual(
            subject.settings(for: url("https://example.com/a"), default: ReaderSettings()).fontSize,
            ReaderSettings.fontSizeRange.upperBound)
    }

    func testResettingASiteMakesItFollowTheDefaultAgain() {
        var chosen = ReaderSettings()
        chosen.fontSize = 30
        var defaults = ReaderSettings()
        defaults.fontSize = 16

        let subject = store()
        let site = url("https://example.com/a")
        subject.set(chosen, for: site)
        XCTAssertEqual(subject.settings(for: site, default: defaults).fontSize, 30)

        subject.reset(site)
        XCTAssertFalse(subject.hasOverride(for: site))
        XCTAssertEqual(subject.settings(for: site, default: defaults).fontSize, 16)
    }

    /// Choosing the default explicitly is still an opinion: it is how you say
    /// "leave this one alone when I change my defaults later".
    func testChoosingTheDefaultIsStillAnOverride() {
        let subject = store()
        let site = url("https://example.com/a")
        subject.set(ReaderSettings(), for: site)
        XCTAssertTrue(subject.hasOverride(for: site))
    }

    func testResetAllForgetsEverySite() {
        let subject = store()
        subject.set(ReaderSettings(), for: url("https://a.com/x"))
        subject.set(ReaderSettings(), for: url("https://b.com/x"))
        subject.resetAll()
        XCTAssertTrue(subject.settingsBySite.isEmpty)
        XCTAssertTrue(store().settingsBySite.isEmpty)
    }

    func testNothingIsRememberedAgainstAURLWithNoSite() {
        let subject = store()
        subject.set(ReaderSettings(), for: url("data:text/html,<p>x</p>"))
        XCTAssertTrue(subject.settingsBySite.isEmpty)
    }
}
