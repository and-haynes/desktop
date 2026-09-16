//  ZenMetrics.swift
//  Numeric constants lifted from Zen's stylesheets, so the iOS chrome is
//  proportioned like the desktop browser rather than eyeballed.
//
//  Where a value only made sense with a mouse (hover-only close buttons, a 5px
//  splitter) it has been adapted for touch and the deviation is noted.

import CoreGraphics

enum ZenMetrics {

    // MARK: Sidebar — zen-tabs/vertical-tabs.css

    /// `--border-radius-medium: 14px` — tab rows, essential tiles, footer buttons.
    static let rowRadius: CGFloat = 14
    /// `--zen-toolbox-padding` (5px, 6px on macOS).
    static let sidebarPadding: CGFloat = 8
    /// `--tab-margin-block: 2px`
    static let rowSpacing: CGFloat = 2
    /// `--tab-inline-padding: 8px`
    static let rowInlinePadding: CGFloat = 10
    /// `--tab-icon-end-margin: 8.5px`
    static let rowIconGap: CGFloat = 8.5
    /// Favicon `border-radius: 4px`
    static let faviconRadius: CGFloat = 4
    static let faviconSize: CGFloat = 17
    /// Touch target, up from the desktop's mouse-sized rows.
    static let rowHeight: CGFloat = 40
    /// The pinned new-tab strip along the bottom of the tab list. Upstream's
    /// new-tab row is list-sized and scrolls away with the list; the thing you
    /// reach for most should not have to be found, so it is a full-width
    /// target at the Apple minimum.
    static let newTabStripHeight: CGFloat = 44
    /// `.pinned-tabs-container-separator { height: 22px }`
    static let separatorHeight: CGFloat = 22
    /// Collapsed sidebar: `--tab-min-width: 48px` + 6px padding each side.
    static let sidebarCollapsedWidth: CGFloat = 60
    /// Drawer width on iPhone; the desktop expanded sidebar is user-resizable.
    static let sidebarWidthPhone: CGFloat = 280
    static let sidebarWidthPad: CGFloat = 268
    /// `#zen-sidebar-foot-buttons { gap: 5px }`
    static let footerGap: CGFloat = 5

    // MARK: Essentials grid

    /// `repeat(auto-fit, minmax(max(23.7%, …), 1fr))` → four across.
    static let essentialsColumns = 4
    /// `gap: 4px`
    static let essentialsGap: CGFloat = 4
    /// `--tab-min-height: 46px` for `#zen-essentials`.
    static let essentialTileHeight: CGFloat = 46
    /// `zen.tabs.essentials.max`, default 12.
    static let maxEssentials = 12

    // MARK: Omnibox — zen-omnibox.css

    /// `--urlbar-container-height: 62px` in the floating state.
    static let omniboxFloatingHeight: CGFloat = 62
    /// Collapsed inline urlbar height.
    static let omniboxPillHeight: CGFloat = 48
    /// A split pane's own bar — slimmer, since it carries fewer controls and
    /// the pane has less room to give.
    static let paneBarHeight: CGFloat = 38
    /// `border-radius: 12px` on the floating input.
    static let omniboxRadius: CGFloat = 12
    /// `min-width: min(90%, 62rem)`
    static let omniboxMaxWidth: CGFloat = 62 * 16
    static let omniboxWidthFraction: CGFloat = 0.92
    /// `box-shadow: 0 30px 140px -15px rgba(0,0,0,0.6…0.8)`. SwiftUI shadows
    /// have no spread, so the radius is scaled to read the same.
    static let omniboxShadowRadius: CGFloat = 45
    static let omniboxShadowY: CGFloat = 18
    /// `#urlbar-results { max-height: 252px }`
    static let suggestionsMaxHeight: CGFloat = 252
    /// `--urlbarView-row-padding-inline: 8px` / `--urlbarview-row-padding-block: 10px`
    static let suggestionRowPaddingInline: CGFloat = 10
    static let suggestionRowPaddingBlock: CGFloat = 10
    /// `.urlbarView-favicon { margin-right: 12px; padding: 6px; border-radius: 3px }`
    static let suggestionIconGap: CGFloat = 12
    static let suggestionIconRadius: CGFloat = 3

    // MARK: Glance — zen-glance.css

    /// `.browserContainer { width: 80%; height: 100% }`. Full height reads as a
    /// wall of page on a phone, so we take 80% of both axes instead and centre.
    static let glanceWidthFraction: CGFloat = 0.88
    static let glanceHeightFraction: CGFloat = 0.78
    /// The parent page scales to 0.97 and dims to 0.3 behind the card.
    static let glanceParentScale: CGFloat = 0.97
    static let glanceParentOpacity: CGFloat = 0.3
    /// `border-radius: 999px` on the floating control buttons.
    static let glanceButtonSize: CGFloat = 40
    /// Spring `bounce: 0`, duration from `zen.glance.animation-duration`.
    static let glanceAnimationDuration: Double = 0.30

    // MARK: Split view — zen-split-view.css

    /// `--zen-element-separation`, capped at 12px upstream.
    static let splitGap: CGFloat = 8
    /// `zen.splitView.min-resize-width`, default 7 (% of the parent).
    static let splitMinFraction: Double = 0.07
    /// Invisible drag strip upstream; a touch needs something to aim at.
    static let splitDividerHitWidth: CGFloat = 28
    static let splitDividerVisualWidth: CGFloat = 4
    /// `outline: 2px solid var(--zen-active-split-outline-color)`
    static let splitActiveOutline: CGFloat = 2
    /// `MAX_TABS = 4`
    static let splitMaxPanes = 4

    // MARK: Compact mode — ZenCompactMode.mjs

    /// Motion spring `bounce: 0, duration: 0.12`.
    static let compactAnimationDuration: Double = 0.12
    /// The reveal grabber. Upstream's 10px hover edge has no touch equivalent
    /// that does not fight the iOS home gesture, so the reveal is an explicit
    /// drag-handle pill with a full-size hit area behind it.
    static let compactGrabberWidth: CGFloat = 36
    static let compactGrabberHeight: CGFloat = 6
    static let compactGrabberHitHeight: CGFloat = 44
    /// The collapsed pill (#008AF, and bare per #008C9 — no favicon, no
    /// domain, just the shape). Shorter than the full bar on purpose, but
    /// still a comfortable target at 34pt with the bar's own padding.
    static let compactPillHeight: CGFloat = 34
    /// With no label to size itself around, the pill needs an explicit
    /// width — Apple's own minimum touch target.
    static let compactPillMinWidth: CGFloat = 44

    // MARK: Content

    /// `--zen-native-inner-radius` — the rounded page surface inside the chrome.
    static let contentRadius: CGFloat = 12
}
