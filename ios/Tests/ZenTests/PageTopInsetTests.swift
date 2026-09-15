//  PageTopInsetTests.swift
//  #008A9. The regression this pins: hiding the status bar must not move the
//  page. It removes the clock, the signal and the battery; the Dynamic Island
//  is hardware and the safe area it occupies stays.

import XCTest

@testable import Zen

final class PageTopInsetTests: XCTestCase {

    /// An iPhone 17's top safe area, island and all.
    private let islandTop: CGFloat = 59

    /// #008BB moved the inset rule onto the *resolved* display, since the
    /// layout cycle is one of the things a space can override. These tests are
    /// about the settings that feed it, so they resolve with no space.
    private func resolvedInsets(_ settings: ZenSettings, safeAreaTop: CGFloat) -> PageTopInsets {
        PageTopInsets.forDisplay(
            EffectiveDisplay.resolve(settings: settings, overrides: nil),
            safeAreaTop: safeAreaTop)
    }

    // MARK: The rule does not see the status-bar setting

    func testTheInsetRuleIsUnchangedByTheStatusBarSetting() {
        var shown = ZenSettings()
        shown.showStatusBar = true
        var hidden = ZenSettings()
        hidden.showStatusBar = false

        XCTAssertEqual(
            resolvedInsets(shown, safeAreaTop: islandTop),
            resolvedInsets(hidden, safeAreaTop: islandTop))
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
            let shown = resolvedInsets(settings, safeAreaTop: top)
            settings.showStatusBar = false
            let hidden = resolvedInsets(settings, safeAreaTop: top)
            XCTAssertEqual(shown, hidden, "the status bar moved the page at safeAreaTop \(top)")
        }
    }

    // MARK: The card starts below the safe area

    func testTheCardStartsBelowTheSafeArea() {
        let insets = resolvedInsets(ZenSettings(), safeAreaTop: islandTop)
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

/// The layout cycle is the *only* input to where the page starts (#008A9,
/// #00887). This is the branch where `pageRunsUnderTopSafeArea` can actually be
/// true, so it is the branch where getting it wrong shows.
final class LayoutPageTopInsetTests: XCTestCase {

    private func settings(_ layout: BrowserLayout, statusBar: Bool) -> ZenSettings {
        var s = ZenSettings()
        s.layout = layout
        s.showStatusBar = statusBar
        return s
    }

    /// See `PageTopInsetTests.resolvedInsets` — the rule takes the resolved
    /// display since #008BB, and these tests carry no space overrides.
    private func resolvedInsets(_ settings: ZenSettings, safeAreaTop: CGFloat) -> PageTopInsets {
        PageTopInsets.forDisplay(
            EffectiveDisplay.resolve(settings: settings, overrides: nil),
            safeAreaTop: safeAreaTop)
    }

    func testCardKeepsTheDesktopInsetAndDoesNotRunUnderTheIsland() {
        for statusBar in [true, false] {
            let insets = resolvedInsets(
                settings(.card, statusBar: statusBar), safeAreaTop: 59)
            XCTAssertFalse(insets.pageUnderTopSafeArea)
            XCTAssertEqual(insets.webTopContentInset, 0)
            XCTAssertEqual(insets.cardTopPadding, ZenMetrics.splitGap)
        }
    }

    func testEdgeToEdgeAndFullScreenGiveThePageTheTopBand() {
        for layout in [BrowserLayout.edgeToEdge, .fullScreen] {
            let insets = resolvedInsets(
                settings(layout, statusBar: true), safeAreaTop: 59)
            XCTAssertTrue(insets.pageUnderTopSafeArea, "\(layout) should reach the top edge")
            XCTAssertEqual(
                insets.webTopContentInset, 59,
                "the page paints to the top but its content starts below the island")
            XCTAssertEqual(insets.cardTopPadding, 0)
        }
    }

    /// The #008A9 bug, in the place it is easiest to reintroduce: "the clock is
    /// gone, so take the space". The island is hardware and is still there.
    func testHidingTheStatusBarMovesNothingInAnyLayout() {
        for layout in BrowserLayout.allCases {
            let shown = resolvedInsets(
                settings(layout, statusBar: true), safeAreaTop: 59)
            let hidden = resolvedInsets(
                settings(layout, statusBar: false), safeAreaTop: 59)
            XCTAssertEqual(shown, hidden, "\(layout) moved when the status bar was hidden")
        }
    }

    /// A proxy read before the window settles can hand us a negative inset.
    func testANegativeSafeAreaIsNotPassedOn() {
        let insets = resolvedInsets(
            settings(.fullScreen, statusBar: true), safeAreaTop: -12)
        XCTAssertEqual(insets.webTopContentInset, 0)
    }
}
