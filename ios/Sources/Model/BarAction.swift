//  BarAction.swift
//  The library of things the URL bar can be made to do.
//
//  Quiche Browser's customisation works because there is *one* vocabulary: the
//  same list of actions fills a button slot, hangs off a long press, and
//  answers a swipe. So this enum is the single library, and the two audiences
//  are filters over it — `slotLibrary` for the things that make sense as a
//  glyph you can tap, `gestureLibrary` for everything a drag or a long press
//  can mean.
//
//  Nothing here knows how to *do* anything: `BarActionRunner` owns that, so a
//  new action is a case plus one line of behaviour, and the model stays a plain
//  value that can be round-tripped through JSON.

import Foundation

enum BarAction: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Explicitly nothing. A gesture set to `none` is off, which is different
    /// from a gesture that is merely unassigned in an older layout file.
    case none

    // Navigation
    case back
    case forward
    /// One button, two meanings: reload a settled page, stop a loading one.
    case reloadStop
    case scrollToTop

    // This page
    case share
    case bookmark
    case copyURL
    case findInPage
    case desktopSite
    /// Picture in Picture for the page's video (#008B0).
    case popOutVideo
    /// Experimental (#008AD): the vault panel for this page. Sits with the
    /// page verbs rather than the places, because what it offers depends
    /// entirely on which page you are on.
    case passwords
    /// Experimental (#008B8): the installed extensions' toolbar buttons, as a
    /// menu. A page verb rather than a place, for the same reason `passwords`
    /// is — an extension action's label, its badge and whether it does
    /// anything at all are all answers about *this* page.
    case extensions

    // Tabs and spaces
    case sidebar
    case newTab
    case closeTab
    case nextTab
    case previousTab
    case spaceSwitcher

    // Window
    case splitView
    case glance
    case layoutCycle
    case compactToggle
    case focusMode
    case eraseFocus

    // Places
    case history
    case localServices
    case settings

    // Bar-only verbs. These have no meaning as a standalone glyph — they are
    // what a gesture does, or the overflow button itself.
    case overflowMenu
    case omnibox
    case closeOmnibox
    case hideBar
    case actionMenu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Nothing"
        case .back: return "Back"
        case .forward: return "Forward"
        case .reloadStop: return "Reload / Stop"
        case .scrollToTop: return "Scroll to Top"
        case .share: return "Share"
        case .bookmark: return "Bookmark"
        case .copyURL: return "Copy URL"
        case .findInPage: return "Find in Page"
        case .desktopSite: return "Desktop Site"
        case .popOutVideo: return "Pop Out Video"
        case .passwords: return "Passwords"
        case .extensions: return "Extensions"
        case .sidebar: return "Tabs"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .spaceSwitcher: return "Spaces"
        case .splitView: return "Split View"
        case .glance: return "Glance"
        case .layoutCycle: return "Layout"
        case .compactToggle: return "Compact"
        case .focusMode: return "Focus Mode"
        case .eraseFocus: return "Erase"
        case .history: return "History"
        case .localServices: return "Local"
        case .settings: return "Settings"
        case .overflowMenu: return "More"
        case .omnibox: return "Address Bar"
        case .closeOmnibox: return "Close Address Bar"
        case .hideBar: return "Hide Bar"
        case .actionMenu: return "Action Menu"
        }
    }

    /// The glyph when the action has no state to reflect. `reloadStop` and
    /// `bookmark` are drawn from `symbol(isLoading:isBookmarked:)` instead.
    var symbol: String {
        switch self {
        case .none: return "circle.dashed"
        case .back: return "chevron.backward"
        case .forward: return "chevron.forward"
        case .reloadStop: return "arrow.clockwise"
        case .scrollToTop: return "arrow.up.to.line"
        case .share: return "square.and.arrow.up"
        case .bookmark: return "bookmark"
        case .copyURL: return "doc.on.doc"
        case .findInPage: return "text.magnifyingglass"
        case .desktopSite: return "desktopcomputer"
        case .popOutVideo: return "pip.enter"
        case .passwords: return "key.fill"
        case .extensions: return "puzzlepiece.extension"
        case .sidebar: return "sidebar.leading"
        case .newTab: return "plus"
        case .closeTab: return "xmark"
        case .nextTab: return "arrow.right.to.line"
        case .previousTab: return "arrow.left.to.line"
        case .spaceSwitcher: return "square.stack.3d.up"
        case .splitView: return "rectangle.split.2x1"
        case .glance: return "rectangle.on.rectangle.angled"
        case .layoutCycle: return "rectangle.inset.filled"
        case .compactToggle: return "rectangle.compress.vertical"
        case .focusMode: return "eye.slash"
        case .eraseFocus: return "trash"
        case .history: return "clock.arrow.circlepath"
        case .localServices: return "network"
        case .settings: return "gearshape"
        case .overflowMenu: return "ellipsis"
        case .omnibox: return "magnifyingglass"
        case .closeOmnibox: return "xmark.circle"
        case .hideBar: return "chevron.down"
        case .actionMenu: return "ellipsis.circle"
        }
    }

    /// The two stateful glyphs, resolved. Kept here rather than in the view so
    /// the preview and the live bar cannot disagree about what a button looks
    /// like.
    func symbol(isLoading: Bool, isBookmarked: Bool) -> String {
        switch self {
        case .reloadStop: return isLoading ? "xmark" : "arrow.clockwise"
        case .bookmark: return isBookmarked ? "bookmark.fill" : "bookmark"
        default: return symbol
        }
    }

    /// Which group the action sits under in the library picker.
    var group: BarActionGroup {
        switch self {
        case .none: return .other
        case .back, .forward, .reloadStop, .scrollToTop: return .navigation
        case .share, .bookmark, .copyURL, .findInPage, .desktopSite, .popOutVideo, .passwords,
            .extensions:
            return .page
        case .sidebar, .newTab, .closeTab, .nextTab, .previousTab, .spaceSwitcher:
            return .tabs
        case .splitView, .glance, .layoutCycle, .compactToggle, .focusMode, .eraseFocus:
            return .window
        case .history, .localServices, .settings: return .places
        case .overflowMenu, .omnibox, .closeOmnibox, .hideBar, .actionMenu: return .other
        }
    }

    /// A button in a slot has to *look* like something and have somewhere to
    /// go. The bar-only verbs do not qualify.
    var fitsASlot: Bool {
        switch self {
        case .none, .omnibox, .closeOmnibox, .hideBar, .actionMenu, .nextTab, .previousTab:
            return false
        default:
            return true
        }
    }

    /// A gesture can mean anything a button can, plus the verbs that only make
    /// sense as a gesture. `overflowMenu` is the one exception in the other
    /// direction — a swipe cannot anchor a popover, so it uses `actionMenu`.
    var fitsAGesture: Bool { self != .overflowMenu }

    /// Presented as a menu rather than a plain tap, which the renderer has to
    /// know before it builds the control.
    var isMenu: Bool {
        self == .overflowMenu || self == .spaceSwitcher || self == .extensions
    }

    static let slotLibrary: [BarAction] = allCases.filter(\.fitsASlot)
    static let gestureLibrary: [BarAction] = allCases.filter(\.fitsAGesture)
}

enum BarActionGroup: String, CaseIterable, Identifiable, Sendable {
    case navigation, page, tabs, window, places, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .navigation: return "Navigation"
        case .page: return "This page"
        case .tabs: return "Tabs & spaces"
        case .window: return "Window"
        case .places: return "Places"
        case .other: return "Gestures only"
        }
    }
}

/// One button in a slot: an action, and optionally a second one on a long
/// press. The identity is its own, not the action's, so the same action can sit
/// in two slots and drag-and-drop can tell the copies apart.
struct BarSlotItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var action: BarAction
    /// Held down rather than tapped. `nil` means the long press does nothing
    /// beyond the system's own press feedback.
    var longPress: BarAction?

    init(id: UUID = UUID(), _ action: BarAction, longPress: BarAction? = nil) {
        self.id = id
        self.action = action
        self.longPress = longPress
    }

    private enum CodingKeys: String, CodingKey { case id, action, longPress }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        // An item whose action we cannot read is a button that would do
        // nothing; decoding it as `.none` would leave a dead glyph in the bar,
        // so the *slot* drops it instead — see `BarLayout.decodeSlot`.
        action = c.lenient(.action, BarAction.none)
        longPress = try? c.decodeIfPresent(BarAction.self, forKey: .longPress)
    }
}

/// Where a gesture on the bar can come from.
enum BarGesture: String, Codable, CaseIterable, Identifiable, Sendable {
    case swipeLeft, swipeRight, swipeUp, swipeDown, longPress, doubleTap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        case .swipeUp: return "Swipe up"
        case .swipeDown: return "Swipe down"
        case .longPress: return "Long press"
        case .doubleTap: return "Double tap"
        }
    }

    var symbol: String {
        switch self {
        case .swipeLeft: return "arrow.left"
        case .swipeRight: return "arrow.right"
        case .swipeUp: return "arrow.up"
        case .swipeDown: return "arrow.down"
        case .longPress: return "hand.tap"
        case .doubleTap: return "hand.tap.fill"
        }
    }

    /// The drag directions, in the order the editor lists them.
    static let swipes: [BarGesture] = [.swipeLeft, .swipeRight, .swipeUp, .swipeDown]

    init?(direction: BarSwipeDirection) {
        switch direction {
        case .left: self = .swipeLeft
        case .right: self = .swipeRight
        case .up: self = .swipeUp
        case .down: self = .swipeDown
        }
    }
}

extension KeyedDecodingContainer {
    /// Decode a key, or fall back.
    ///
    /// Two failures collapse into the same answer on purpose. A *missing* key
    /// is an older file that predates the setting. A key that is present but
    /// unreadable — a `position` of `"floatingLeft"` written by a build from
    /// next month — is a newer file. Neither is a reason to throw away
    /// somebody's whole bar layout, which is what a synthesized `Decodable`
    /// would do. (`ZenSettings` learned the missing-key half of this lesson the
    /// hard way; this is the other half.)
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        do {
            return try decodeIfPresent(T.self, forKey: key) ?? fallback
        } catch {
            return fallback
        }
    }
}
