//  PageTopInsets.swift
//  Where the page begins at the top of the window.
//
//  #008A9. Hiding the status bar (#00899) takes away the clock, the signal and
//  the battery — and nothing else. The Dynamic Island is hardware: it is still
//  there, iOS still reports a top safe-area inset for it, and content that
//  drops that inset renders under the island and out of frame. An earlier cut
//  (add5a8d) handed the page the top edge outright when the status bar was
//  hidden; this is the correction.
//
//  So none of the numbers here are a function of `showStatusBar`. They are a
//  function of the layout and of the window's own safe area — and
//  `PageTopInsetTests` pins exactly that, by varying the whole settings value
//  and asserting the result does not move.

import CoreGraphics

/// The top of the window, divided between the chrome and the page.
struct PageTopInsets: Equatable, Sendable {
    /// Whether the page surface itself runs under the top safe area. False for
    /// Zen's card layout, where the card starts below the safe area and the
    /// island has nothing of ours to cover.
    var pageUnderTopSafeArea: Bool
    /// Padding above the content card.
    var cardTopPadding: CGFloat
    /// The web view's scroll-view top content inset. Non-zero only where the
    /// page runs under the island: the page still *paints* to the top edge as
    /// it scrolls, but its content — and its own `position: fixed` header —
    /// starts below the island rather than behind it.
    var webTopContentInset: CGFloat

    static func resolve(
        pageUnderTopSafeArea: Bool, safeAreaTop: CGFloat, gap: CGFloat
    ) -> PageTopInsets {
        PageTopInsets(
            pageUnderTopSafeArea: pageUnderTopSafeArea,
            // Running under the safe area means the card has no frame to draw
            // above it; otherwise it sits in the chrome by the usual gap.
            cardTopPadding: pageUnderTopSafeArea ? 0 : gap,
            // A negative safe area is not a thing, but a proxy read before the
            // window settles can hand us one.
            webTopContentInset: pageUnderTopSafeArea ? max(0, safeAreaTop) : 0)
    }

    /// What `RootView` runs.
    ///
    /// Takes the *resolved* display rather than the global settings since
    /// #008BB: the layout cycle is one of the things a space can override, and
    /// a page inset computed from the global would be inset for the wrong
    /// layout in every such space.
    static func forDisplay(_ display: EffectiveDisplay, safeAreaTop: CGFloat) -> PageTopInsets {
        resolve(
            pageUnderTopSafeArea: display.pageRunsUnderTopSafeArea,
            safeAreaTop: safeAreaTop, gap: ZenMetrics.splitGap)
    }
}
