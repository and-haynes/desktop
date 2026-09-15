//  PageTopInsetTests.swift
//  #008A9. The regression this pins: hiding the status bar must not move the
//  page. It removes the clock, the signal and the battery; the Dynamic Island
//  is hardware and the safe area it occupies stays.

import XCTest

@testable import Zen

final class PageTopInsetTests: XCTestCase {

    /// An iPhone 17's top safe area, island and all.
    private let islandTop: CGFloat = 59

    // MARK: The rule does not see the status-bar setting

    func testTheInsetRuleIsUnchangedByTheStatusBarSetting() {
        var shown = ZenSettings()
        shown.showStatusBar = true
        var hidden = ZenSettings()
        hidden.showStatusBar = false

        XCTAssertEqual(
            PageTopInsets.forSettings(shown, safeAreaTop: islandTop),
            PageTopInsets.forSettings(hidden, safeAreaTop: islandTop))
    }

    /// Belt and braces: every other setting held constant, flipping the status
    /// bar on a settings value that has been changed in other ways still moves
    /// nothing.
    func testTheRuleIsUnchangedAcrossAWholeSettingsValue() {
        var settings = ZenSettings()
        settings.compactModeEnabled = true
        settings.sidebarEdge = .trailing
        settings.appearance = .dark

        for top in [CGFloat(0), 20, islandTop, 62] {
            settings.showStatusBar = true
            let shown = PageTopInsets.forSettings(settings, safeAreaTop: top)
            settings.showStatusBar = false
            let hidden = PageTopInsets.forSettings(settings, safeAreaTop: top)
            XCTAssertEqual(shown, hidden, "the status bar moved the page at safeAreaTop \(top)")
        }
    }

    // MARK: The card starts below the safe area

    func testTheCardStartsBelowTheSafeArea() {
        let insets = PageTopInsets.forSettings(ZenSettings(), safeAreaTop: islandTop)
        XCTAssertFalse(insets.pageUnderTopSafeArea)
        XCTAssertEqual(insets.cardTopPadding, ZenMetrics.splitGap)
        // Nothing of ours is under the island, so the page needs no inset of
        // its own to clear it.
        XCTAssertEqual(insets.webTopContentInset, 0)
    }

    // MARK: A page that *does* take the top band

    /// The layout cycle on `experimental` is what turns this on. The rule is
    /// here so both branches run the same one.
    func testAPageUnderTheSafeAreaGetsAScrollInsetInstead() {
        let insets = PageTopInsets.resolve(
            pageUnderTopSafeArea: true, safeAreaTop: islandTop, gap: ZenMetrics.splitGap)
        XCTAssertEqual(insets.cardTopPadding, 0)
        XCTAssertEqual(insets.webTopContentInset, islandTop)
    }

    /// A device with no island reports no top inset, and then there is nothing
    /// to push the page down by.
    func testNoSafeAreaMeansNoInset() {
        let insets = PageTopInsets.resolve(
            pageUnderTopSafeArea: true, safeAreaTop: 0, gap: ZenMetrics.splitGap)
        XCTAssertEqual(insets.webTopContentInset, 0)
    }

    /// A proxy read before the window settles can hand back a negative inset;
    /// pushing the page *up* by it would be the original bug again.
    func testANegativeSafeAreaIsClampedAwayRatherThanApplied() {
        let insets = PageTopInsets.resolve(
            pageUnderTopSafeArea: true, safeAreaTop: -12, gap: ZenMetrics.splitGap)
        XCTAssertEqual(insets.webTopContentInset, 0)
    }
}

/// The strip the scroll inset opens up is painted in the page's own colour.
/// Getting this wrong is what made the first attempt a black bar on every
/// light page.
final class CSSColorTests: XCTestCase {

    func testParsesTheRGBFormComputedStyleReturns() {
        let color = CSSColor.parse("rgb(255, 255, 255)")
        XCTAssertEqual(color?.alpha, 1)
        XCTAssertEqual(color?.red ?? 0, 1, accuracy: 0.001)
        XCTAssertFalse(color?.isTransparent ?? true)
    }

    func testParsesRGBAWithAFractionalAlpha() {
        let color = CSSColor.parse("rgba(34, 34, 34, 0.5)")
        XCTAssertEqual(color?.alpha ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(color?.green ?? 0, 34.0 / 255, accuracy: 0.001)
    }

    /// The whole point. An unstyled page computes to this, and treating it as
    /// black is the black slab.
    func testAFullyTransparentBackgroundIsRecognisedAsSuch() {
        let color = CSSColor.parse("rgba(0, 0, 0, 0)")
        XCTAssertEqual(color?.isTransparent, true)
    }

    func testParsesTheSpaceSeparatedForm() {
        let color = CSSColor.parse("rgb(17 34 51 / 50%)")
        XCTAssertEqual(color?.alpha ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(color?.blue ?? 0, 51.0 / 255, accuracy: 0.001)
    }

    func testRejectsWhatItDoesNotUnderstand() {
        XCTAssertNil(CSSColor.parse("transparent"))
        XCTAssertNil(CSSColor.parse("#ffffff"))
        XCTAssertNil(CSSColor.parse("rgb(1, 2)"))
        XCTAssertNil(CSSColor.parse("rgb(1, 2, 300)"))
        XCTAssertNil(CSSColor.parse(""))
    }
}
