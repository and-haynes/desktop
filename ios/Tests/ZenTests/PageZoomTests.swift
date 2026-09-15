//  PageZoomTests.swift
//  The text-size ladder and the per-site memory (#008B7).
//
//  Two things are worth pinning here. The first is the step arithmetic, which
//  has exactly one interesting case: a value that is not on the ladder, because
//  that is what a restored file or a future build with more rungs produces, and
//  a naive "index + 1" walks the wrong way for it. The second is the lookup
//  order — per-site beats global, an absent site *inherits* rather than
//  defaults — since the whole feature is the sticking.

import XCTest

@testable import Zen

@MainActor
final class PageZoomTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-zoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> PageZoomStore {
        PageZoomStore(file: JSONFileStore<[String: Double]>(name: "zoom.json", directory: directory))
    }

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    // MARK: The ladder

    func testTheLadderRunsFromFiftyToThreeHundredAndContainsOneHundred() {
        XCTAssertEqual(PageZoom.minimum, 0.5)
        XCTAssertEqual(PageZoom.maximum, 3.0)
        XCTAssertTrue(PageZoom.steps.contains(PageZoom.standard))
        XCTAssertEqual(PageZoom.steps, PageZoom.steps.sorted(), "the ladder must be ascending")
    }

    func testSteppingWalksTheLadderOneRungAtATime() {
        var zoom = PageZoom.standard
        zoom = PageZoom.larger(than: zoom)
        XCTAssertEqual(zoom, 1.15)
        zoom = PageZoom.larger(than: zoom)
        XCTAssertEqual(zoom, 1.25)
        zoom = PageZoom.smaller(than: zoom)
        XCTAssertEqual(zoom, 1.15)
        zoom = PageZoom.smaller(than: zoom)
        XCTAssertEqual(zoom, 1.0)
        zoom = PageZoom.smaller(than: zoom)
        XCTAssertEqual(zoom, 0.85)
    }

    func testSteppingStopsAtEitherEndRatherThanWrapping() {
        XCTAssertEqual(PageZoom.larger(than: PageZoom.maximum), PageZoom.maximum)
        XCTAssertEqual(PageZoom.smaller(than: PageZoom.minimum), PageZoom.minimum)
        XCTAssertTrue(PageZoom.isAtMaximum(3.0))
        XCTAssertTrue(PageZoom.isAtMinimum(0.5))
        XCTAssertFalse(PageZoom.isAtMaximum(PageZoom.standard))
    }

    /// The case "index + 1" gets wrong: 1.07 is between two rungs, and larger
    /// must move *up* rather than snapping to the rung below first.
    func testSteppingFromAValueThatIsNotOnTheLadder() {
        XCTAssertEqual(PageZoom.larger(than: 1.07), 1.15)
        XCTAssertEqual(PageZoom.smaller(than: 1.07), 1.0)
        XCTAssertEqual(PageZoom.larger(than: 0.4), 0.75, "an out-of-range value clamps first")
        XCTAssertEqual(PageZoom.smaller(than: 9), 2.5)
    }

    func testAnAbsurdValueIsClamped() {
        XCTAssertEqual(PageZoom.clamp(40), 3.0)
        XCTAssertEqual(PageZoom.clamp(0), 0.5)
        // Not a number and not finite are the same answer: there is no
        // sensible clamp for either, so the ladder's own default wins.
        XCTAssertEqual(PageZoom.clamp(.nan), PageZoom.standard)
        XCTAssertEqual(PageZoom.clamp(.infinity), PageZoom.standard)
    }

    func testTheReadoutIsWholePercent() {
        XCTAssertEqual(PageZoom.percentLabel(1), "100%")
        XCTAssertEqual(PageZoom.percentLabel(1.15), "115%")
        XCTAssertEqual(PageZoom.percentLabel(0.5), "50%")
        XCTAssertEqual(PageZoom.percentLabel(3), "300%")
    }

    // MARK: What counts as one site

    func testSubdomainsOfOneSiteShareAZoom() throws {
        XCTAssertEqual(
            PageZoom.siteKey(for: try url("https://en.wikipedia.org/wiki/Zen")), "wikipedia.org")
        XCTAssertEqual(PageZoom.siteKey(for: try url("https://wikipedia.org/")), "wikipedia.org")
    }

    func testAPublicSuffixIsNotASite() throws {
        XCTAssertEqual(PageZoom.siteKey(for: try url("https://www.bbc.co.uk/news")), "bbc.co.uk")
        XCTAssertEqual(
            PageZoom.siteKey(for: try url("https://one.github.io/x")), "one.github.io")
        XCTAssertNotEqual(
            PageZoom.siteKey(for: try url("https://two.github.io/x")),
            PageZoom.siteKey(for: try url("https://one.github.io/x")))
    }

    /// The homelab is full of these, and grouping every address on the subnet
    /// under one "site" would mean zooming the router zoomed the NAS.
    func testBareHostsAndAddressesAreTheirOwnSite() throws {
        XCTAssertEqual(PageZoom.siteKey(for: try url("http://10.0.0.42:8092/")), "10.0.0.42")
        XCTAssertEqual(PageZoom.siteKey(for: try url("http://pi-a/")), "pi-a")
        XCTAssertNotEqual(
            PageZoom.siteKey(for: try url("http://10.0.0.42/")),
            PageZoom.siteKey(for: try url("http://10.0.0.43/")))
    }

    func testThereIsNothingToRememberAgainstAboutABlankPage() throws {
        XCTAssertNil(PageZoom.siteKey(for: nil))
        XCTAssertNil(PageZoom.siteKey(for: try url("about:blank")))
        XCTAssertNil(PageZoom.siteKey(for: try url("data:text/html,hi")))
    }

    // MARK: Lookup

    func testASiteWithNoOpinionFollowsTheGlobalDefault() throws {
        let zoom = store()
        XCTAssertEqual(zoom.zoom(for: try url("https://example.com"), default: 1.25), 1.25)
        XCTAssertFalse(zoom.hasOverride(for: try url("https://example.com")))
    }

    func testAPerSiteChoiceBeatsTheGlobalDefault() throws {
        let zoom = store()
        zoom.set(1.5, for: try url("https://example.com/a"))
        XCTAssertEqual(zoom.zoom(for: try url("https://example.com/b"), default: 1.25), 1.5)
        XCTAssertEqual(
            zoom.zoom(for: try url("https://www.example.com/c"), default: 1.25), 1.5,
            "a subdomain is the same site")
        XCTAssertEqual(
            zoom.zoom(for: try url("https://other.test"), default: 1.25), 1.25,
            "and only that site")
    }

    /// An explicit 100 % is an opinion — "this one site should ignore my
    /// larger default" — and must not be mistaken for having none.
    func testAnExplicitOneHundredPercentIsStillAnOverride() throws {
        let zoom = store()
        zoom.set(1.0, for: try url("https://example.com"))
        XCTAssertTrue(zoom.hasOverride(for: try url("https://example.com")))
        XCTAssertEqual(zoom.zoom(for: try url("https://example.com"), default: 1.5), 1.0)
    }

    func testResettingASiteGivesItBackTheGlobalDefault() throws {
        let zoom = store()
        zoom.set(2.0, for: try url("https://example.com"))
        zoom.reset(try url("https://example.com"))
        XCTAssertFalse(zoom.hasOverride(for: try url("https://example.com")))
        XCTAssertEqual(zoom.zoom(for: try url("https://example.com"), default: 1.15), 1.15)
    }

    func testResetAllForgetsEverySite() throws {
        let zoom = store()
        zoom.set(2.0, for: try url("https://a.test"))
        zoom.set(0.75, for: try url("https://b.test"))
        XCTAssertEqual(zoom.zoomBySite.count, 2)
        zoom.resetAll()
        XCTAssertTrue(zoom.zoomBySite.isEmpty)
    }

    // MARK: Persistence

    func testAChoiceSurvivesARelaunch() throws {
        let first = store()
        first.set(1.75, for: try url("https://example.com/login"))

        let second = store()
        XCTAssertEqual(second.zoom(for: try url("https://example.com/"), default: 1), 1.75)
    }

    /// A hand-edited file must not be able to hand WebKit a 40× page.
    func testAHostileFileIsClampedOnLoad() throws {
        let file = JSONFileStore<[String: Double]>(name: "zoom.json", directory: directory)
        file.save(["example.com": 40, "other.test": -3])
        let zoom = PageZoomStore(file: file)
        XCTAssertEqual(zoom.zoom(for: try url("https://example.com"), default: 1), PageZoom.maximum)
        XCTAssertEqual(zoom.zoom(for: try url("https://other.test"), default: 1), PageZoom.minimum)
    }

    // MARK: The command

    func testTheCommandWalksTheLadderAndResetIsAnAbsence() throws {
        let zoom = store()
        let page = try url("https://example.com")

        XCTAssertEqual(
            PageZoomCommand.apply(.larger, url: page, store: zoom, default: 1), 1.15)
        XCTAssertEqual(
            PageZoomCommand.apply(.larger, url: page, store: zoom, default: 1), 1.25)
        XCTAssertEqual(
            PageZoomCommand.apply(.smaller, url: page, store: zoom, default: 1), 1.15)

        XCTAssertEqual(PageZoomCommand.apply(.reset, url: page, store: zoom, default: 1.5), 1.5)
        XCTAssertFalse(zoom.hasOverride(for: page))
    }

    /// Stepping past the end must not write an entry: a site sitting at 300 %
    /// with no override is not the same as one pinned there by a tap that did
    /// nothing.
    func testSteppingPastTheEndOfTheLadderChangesNothing() throws {
        let zoom = store()
        let page = try url("https://example.com")
        XCTAssertEqual(
            PageZoomCommand.apply(.smaller, url: page, store: zoom, default: PageZoom.minimum),
            PageZoom.minimum)
        XCTAssertFalse(zoom.hasOverride(for: page))
    }

    func testResolveKnowsNothingAboutStorage() {
        XCTAssertEqual(PageZoomCommand.resolve(.larger, current: 1), 1.15)
        XCTAssertEqual(PageZoomCommand.resolve(.smaller, current: 1), 0.85)
        XCTAssertNil(PageZoomCommand.resolve(.reset, current: 2))
    }

    // MARK: The setting

    func testTheDefaultSurvivesASessionRoundTripAndAnOlderFile() throws {
        var settings = ZenSettings()
        settings.defaultPageZoom = 1.25
        let restored = try JSONDecoder().decode(
            ZenSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.defaultPageZoom, 1.25)

        let older = try JSONDecoder().decode(
            ZenSettings.self, from: Data(#"{"searchEngine":"google"}"#.utf8))
        XCTAssertEqual(older.defaultPageZoom, PageZoom.standard)
    }

    func testAHostileSettingsFileCannotSetAnAbsurdDefault() throws {
        let settings = try JSONDecoder().decode(
            ZenSettings.self, from: Data(#"{"defaultPageZoom":99}"#.utf8))
        XCTAssertEqual(settings.defaultPageZoom, PageZoom.maximum)
    }
}
