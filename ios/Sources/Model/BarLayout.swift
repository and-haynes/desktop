//  BarLayout.swift
//  Everything about the URL bar that is a choice rather than a constant.
//
//  Quiche Browser on iOS is the reference here: its bar is adjustable in almost
//  every dimension, and the thing that makes that coherent rather than a pile
//  of toggles is that *one* value describes the bar. So this is one persisted,
//  versioned document — position, geometry, look, contents, buttons, gestures
//  and auto-hide — and every view that draws a bar reads it.
//
//  Two rules hold the format together:
//
//  1. **Decoding never throws.** Every field goes through `lenient`, so a file
//     written by an older build picks up defaults for what it predates, and a
//     file written by a *newer* one keeps everything this build understands
//     instead of losing the lot. Unknown keys are ignored by Codable already.
//  2. **The presets are the same type.** "Zen", "Safari-like", "Quiche-like"
//     and "Minimal" are `BarLayout` values, not a parallel description that can
//     drift from what the editor produces.

import CoreGraphics
import Foundation

// MARK: - Position and shape

enum BarPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The default: a pill over the page, clear of the home indicator.
    case bottomFloating
    /// At the bottom, in the layout flow, pushing the page up.
    case bottomDocked
    /// Above the page, where a desktop browser puts it.
    case topDocked

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bottomFloating: return "Floating"
        case .bottomDocked: return "Bottom"
        case .topDocked: return "Top"
        }
    }

    var symbol: String {
        switch self {
        case .bottomFloating: return "rectangle.bottomthird.inset.filled"
        case .bottomDocked: return "dock.rectangle"
        case .topDocked: return "rectangle.topthird.inset.filled"
        }
    }

    /// Whether the bar sits *over* the page rather than taking room from it.
    var isFloating: Bool { self == .bottomFloating }
    var isTop: Bool { self == .topDocked }
}

/// The three sizes the editor offers as presets. The stored value is a number
/// of points, so the slider can sit anywhere between them.
enum BarHeightStep: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }

    var points: Double {
        switch self {
        case .small: return 40
        case .medium: return 48
        case .large: return 58
        }
    }

    /// The nearest step to an arbitrary height, for showing which one is on.
    static func nearest(to points: Double) -> BarHeightStep {
        allCases.min { abs($0.points - points) < abs($1.points - points) } ?? .medium
    }
}

// MARK: - Contents

enum BarLabelStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `zen-browser.app` — what the bar has always shown.
    case domain
    /// The whole thing, truncated in the middle.
    case fullURL
    /// The page's `<title>`, falling back to the domain before one arrives.
    case pageTitle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .domain: return "Domain"
        case .fullURL: return "Full URL"
        case .pageTitle: return "Page title"
        }
    }
}

enum BarProgressStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    /// A hairline along the bar's bottom edge, as a desktop browser draws it.
    case line
    /// The bar's own surface fills from the left — no extra pixels spent.
    case fill

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .line: return "Line"
        case .fill: return "Fill"
        }
    }
}

/// What sits inside the pill, left of the buttons.
struct BarContents: Codable, Equatable, Sendable {
    var showsFavicon: Bool = false
    /// The lock / warning glyph, which is also the button onto the certificate
    /// record (#0089A).
    var showsSecurityBadge: Bool = true
    var label: BarLabelStyle = .domain
    var progress: BarProgressStyle = .line
    /// A magnifier inside the pill that opens find-in-page without a trip
    /// through the overflow menu.
    var showsFindButton: Bool = false

    init() {}

    init(
        showsFavicon: Bool, showsSecurityBadge: Bool, label: BarLabelStyle,
        progress: BarProgressStyle, showsFindButton: Bool
    ) {
        self.showsFavicon = showsFavicon
        self.showsSecurityBadge = showsSecurityBadge
        self.label = label
        self.progress = progress
        self.showsFindButton = showsFindButton
    }

    private enum CodingKeys: String, CodingKey {
        case showsFavicon, showsSecurityBadge, label, progress, showsFindButton
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BarContents()
        showsFavicon = c.lenient(.showsFavicon, fallback.showsFavicon)
        showsSecurityBadge = c.lenient(.showsSecurityBadge, fallback.showsSecurityBadge)
        label = c.lenient(.label, fallback.label)
        progress = c.lenient(.progress, fallback.progress)
        showsFindButton = c.lenient(.showsFindButton, fallback.showsFindButton)
    }
}

// MARK: - Auto-hide

enum BarAutoHide: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Always there.
    case never
    /// Out of the way while the page is moving, back shortly after it settles.
    /// Reuses compact mode's `compactHideDelay` for "shortly".
    case onScroll
    /// Defer to compact mode: hidden until the grabber or a scroll reveals it.
    case compact

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: return "Never"
        case .onScroll: return "On scroll"
        case .compact: return "Compact"
        }
    }

    var detail: String {
        switch self {
        case .never: return "The bar is always on screen."
        case .onScroll:
            return
                "The bar steps aside while the page is moving and comes back "
                + "shortly after it settles, on the compact-mode delay."
        case .compact:
            return
                "Follow compact mode: the bar stays hidden until the grabber "
                + "above the home indicator — or a scroll — brings it back."
        }
    }
}

/// What changes when the phone is turned on its side. Both are optional
/// because "no override" and "override with the same value" are different
/// things once the portrait setting is edited afterwards.
struct BarLandscapeOverride: Codable, Equatable, Sendable {
    var position: BarPosition?
    var autoHide: BarAutoHide?

    var isEmpty: Bool { position == nil && autoHide == nil }

    init(position: BarPosition? = nil, autoHide: BarAutoHide? = nil) {
        self.position = position
        self.autoHide = autoHide
    }

    private enum CodingKeys: String, CodingKey { case position, autoHide }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try? c.decodeIfPresent(BarPosition.self, forKey: .position)
        autoHide = try? c.decodeIfPresent(BarAutoHide.self, forKey: .autoHide)
    }
}

/// Where the bar's glyph colour comes from.
enum BarAccentSource: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Follow the space, as everything else in the chrome does.
    case space
    /// One colour whatever space you are in.
    case fixed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .space: return "From the space"
        case .fixed: return "Fixed"
        }
    }
}

// MARK: - The layout

struct BarLayout: Codable, Equatable, Sendable {
    /// Bumped only for a change the *decoder* has to know about. Adding a field
    /// does not need it — `lenient` already handles that.
    static let currentVersion = 1

    /// A slot holds a few glyphs before it stops being a bar and starts being a
    /// toolbar. Four is what fits beside a readable URL on a 6.1-inch phone.
    static let maxSlotItems = 4
    /// The overflow menu is a list, so it can afford more — but not unbounded,
    /// or it scrolls and stops being a menu.
    static let maxOverflowItems = 12

    static let minHeight: Double = 34
    static let maxHeight: Double = 64
    static let maxCornerRadius: Double = 32
    static let maxHorizontalMargin: Double = 40
    static let maxVerticalOffset: Double = 24
    static let minURLFontSize: Double = 11
    static let maxURLFontSize: Double = 20

    var version: Int = BarLayout.currentVersion

    // Position & shape
    var position: BarPosition = .bottomFloating
    var height: Double = BarHeightStep.medium.points
    var cornerRadius: Double = Double(ZenMetrics.rowRadius)
    var horizontalMargin: Double = 10
    var verticalOffset: Double = 4
    /// A pill is inset and rounded; full width runs edge to edge and squares
    /// off its outer corners.
    var isPill: Bool = true

    // Fill & look
    /// `nil` means "use the global Bar fill setting", which is where Liquid
    /// Glass / Matte / Transparent already lives (#00891). A preset can pin it.
    var fill: BarFill?
    /// A flat colour behind the bar instead of a material. Wins over `fill`.
    var customColor: ZenColor?
    var customColorOpacity: Double = 0.85
    /// 0 = barely there, 1 = the full material. Scales the tint the material
    /// carries, which is the only part of a system blur an app can move.
    var blurStrength: Double = 1
    var showsBorder: Bool = true
    var showsShadow: Bool = true
    var urlFontSize: Double = 15
    var accentSource: BarAccentSource = .space
    var fixedAccent: ZenColor?
    /// Whether the bar's own controls and gestures fire haptics. The global
    /// level still applies on top — this cannot make a silenced phone buzz.
    var haptics: Bool = true

    // Contents
    var contents = BarContents()

    // Buttons
    var leftSlots: [BarSlotItem] = []
    var rightSlots: [BarSlotItem] = []
    var overflowSlots: [BarSlotItem] = []

    // Gestures
    var gestures: [BarGesture: BarAction] = [:]

    // Auto-hide
    var autoHide: BarAutoHide = .never
    var landscape = BarLandscapeOverride()

    /// Which preset this came from, so the editor can offer "reset to preset"
    /// and say what it is resetting to. Cleared the moment anything is edited.
    var presetID: String?

    init() {
        self = BarPreset.zen.layout
    }

    /// The memberwise-ish initialiser the presets use. Private so nothing else
    /// can build a layout that skipped the clamping in `normalised()`.
    fileprivate init(raw: Void) {
        _ = raw
    }

    // MARK: Derived

    var heightStep: BarHeightStep { BarHeightStep.nearest(to: height) }

    /// The fill actually used, given the global setting as a fallback.
    func resolvedFill(default globalFill: BarFill) -> BarFill { fill ?? globalFill }

    /// Position for the current orientation.
    func position(landscape isLandscape: Bool) -> BarPosition {
        (isLandscape ? landscape.position : nil) ?? position
    }

    /// Auto-hide rule for the current orientation.
    func autoHide(landscape isLandscape: Bool) -> BarAutoHide {
        (isLandscape ? landscape.autoHide : nil) ?? autoHide
    }

    func slots(_ slot: BarSlot) -> [BarSlotItem] {
        switch slot {
        case .left: return leftSlots
        case .right: return rightSlots
        case .overflow: return overflowSlots
        }
    }

    /// Every action the bar can currently reach, which is what tells the
    /// overflow button whether it has anything to show.
    var hasOverflow: Bool { !overflowSlots.isEmpty }

    // MARK: Mutation

    /// True when `slot` has room for one more.
    func canAdd(to slot: BarSlot) -> Bool { slots(slot).count < slot.capacity }

    /// Add an action, refusing rather than silently dropping when the slot is
    /// full — the editor turns that `false` into the shake-and-say-why.
    @discardableResult
    mutating func add(_ action: BarAction, to slot: BarSlot) -> Bool {
        guard action.fitsASlot, canAdd(to: slot) else { return false }
        mutate(slot) { $0.append(BarSlotItem(action)) }
        presetID = nil
        return true
    }

    @discardableResult
    mutating func insert(_ item: BarSlotItem, into slot: BarSlot, at index: Int) -> Bool {
        guard item.action.fitsASlot, canAdd(to: slot) else { return false }
        mutate(slot) { $0.insert(item, at: min(max(index, 0), $0.count)) }
        presetID = nil
        return true
    }

    mutating func remove(_ id: UUID) {
        for slot in BarSlot.allCases {
            mutate(slot) { $0.removeAll { $0.id == id } }
        }
        presetID = nil
    }

    /// Move an item to a position in a slot — the drop half of drag-and-drop.
    /// Moving within a slot is always allowed even at capacity; only moving
    /// *into* a full slot is refused.
    @discardableResult
    mutating func move(_ id: UUID, to slot: BarSlot, at index: Int) -> Bool {
        guard let item = item(id) else { return false }
        let sameSlot = self.slot(containing: id) == slot
        guard sameSlot || canAdd(to: slot) else { return false }
        for candidate in BarSlot.allCases {
            mutate(candidate) { $0.removeAll { $0.id == id } }
        }
        mutate(slot) { $0.insert(item, at: min(max(index, 0), $0.count)) }
        presetID = nil
        return true
    }

    mutating func setLongPress(_ action: BarAction?, for id: UUID) {
        for slot in BarSlot.allCases {
            mutate(slot) { items in
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index].longPress = action == BarAction.none ? nil : action
            }
        }
        presetID = nil
    }

    mutating func setGesture(_ action: BarAction, for gesture: BarGesture) {
        gestures[gesture] = action
        presetID = nil
    }

    func item(_ id: UUID) -> BarSlotItem? {
        for slot in BarSlot.allCases {
            if let found = slots(slot).first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    func slot(containing id: UUID) -> BarSlot? {
        BarSlot.allCases.first { slot in slots(slot).contains(where: { $0.id == id }) }
    }

    private mutating func mutate(_ slot: BarSlot, _ body: (inout [BarSlotItem]) -> Void) {
        switch slot {
        case .left: body(&leftSlots)
        case .right: body(&rightSlots)
        case .overflow: body(&overflowSlots)
        }
    }

    /// Clamp everything into range and drop anything nonsensical. Applied on
    /// decode and on import, so a hand-edited or hostile JSON file cannot
    /// produce a 4000pt bar or a slot with thirty buttons in it.
    func normalised() -> BarLayout {
        var copy = self
        copy.version = BarLayout.currentVersion
        copy.height = min(max(height, Self.minHeight), Self.maxHeight)
        copy.cornerRadius = min(max(cornerRadius, 0), Self.maxCornerRadius)
        copy.horizontalMargin = min(max(horizontalMargin, 0), Self.maxHorizontalMargin)
        copy.verticalOffset = min(max(verticalOffset, 0), Self.maxVerticalOffset)
        copy.customColorOpacity = min(max(customColorOpacity, 0), 1)
        copy.blurStrength = min(max(blurStrength, 0), 1)
        copy.urlFontSize = min(max(urlFontSize, Self.minURLFontSize), Self.maxURLFontSize)
        for slot in BarSlot.allCases {
            copy.mutate(slot) { items in
                items = Array(items.filter { $0.action.fitsASlot }.prefix(slot.capacity))
            }
        }
        copy.gestures = gestures.filter { $0.value.fitsAGesture }
        if copy.landscape.isEmpty { copy.landscape = BarLandscapeOverride() }
        return copy
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version, position, height, cornerRadius, horizontalMargin, verticalOffset, isPill
        case fill, customColor, customColorOpacity, blurStrength, showsBorder, showsShadow
        case urlFontSize, accentSource, fixedAccent, haptics, contents
        case leftSlots, rightSlots, overflowSlots, gestures, autoHide, landscape, presetID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BarPreset.zen.layout
        version = c.lenient(.version, BarLayout.currentVersion)
        position = c.lenient(.position, fallback.position)
        height = c.lenient(.height, fallback.height)
        cornerRadius = c.lenient(.cornerRadius, fallback.cornerRadius)
        horizontalMargin = c.lenient(.horizontalMargin, fallback.horizontalMargin)
        verticalOffset = c.lenient(.verticalOffset, fallback.verticalOffset)
        isPill = c.lenient(.isPill, fallback.isPill)
        fill = try? c.decodeIfPresent(BarFill.self, forKey: .fill)
        customColor = try? c.decodeIfPresent(ZenColor.self, forKey: .customColor)
        customColorOpacity = c.lenient(.customColorOpacity, fallback.customColorOpacity)
        blurStrength = c.lenient(.blurStrength, fallback.blurStrength)
        showsBorder = c.lenient(.showsBorder, fallback.showsBorder)
        showsShadow = c.lenient(.showsShadow, fallback.showsShadow)
        urlFontSize = c.lenient(.urlFontSize, fallback.urlFontSize)
        accentSource = c.lenient(.accentSource, fallback.accentSource)
        fixedAccent = try? c.decodeIfPresent(ZenColor.self, forKey: .fixedAccent)
        haptics = c.lenient(.haptics, fallback.haptics)
        contents = c.lenient(.contents, fallback.contents)
        leftSlots = Self.decodeSlot(c, .leftSlots, fallback.leftSlots)
        rightSlots = Self.decodeSlot(c, .rightSlots, fallback.rightSlots)
        overflowSlots = Self.decodeSlot(c, .overflowSlots, fallback.overflowSlots)
        gestures = Self.decodeGestures(c, fallback: fallback.gestures)
        autoHide = c.lenient(.autoHide, fallback.autoHide)
        landscape = c.lenient(.landscape, BarLandscapeOverride())
        // Encoded explicitly, null and all, so "no key" (an older file, or an
        // empty document) and "deliberately not a preset any more" stay
        // different answers — otherwise every edited layout would read back as
        // the preset it started from.
        presetID =
            c.contains(.presetID)
            ? (try? c.decodeIfPresent(String.self, forKey: .presetID)) ?? nil
            : fallback.presetID
        self = normalised()
    }

    /// A slot the decoder cannot read at all falls back; individual items it
    /// cannot read are dropped, because one unknown button is not a reason to
    /// lose the other three.
    private static func decodeSlot(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, _ fallback: [BarSlotItem]
    ) -> [BarSlotItem] {
        guard let items = try? c.decodeIfPresent([BarSlotItem].self, forKey: key) else {
            return fallback
        }
        return items.filter { $0.action.fitsASlot }
    }

    /// Gestures are stored as a plain `{ "swipeUp": "sidebar" }` object rather
    /// than Codable's array-of-pairs encoding for dictionaries with non-String
    /// keys, so an exported layout is something a person can edit.
    private static func decodeGestures(
        _ c: KeyedDecodingContainer<CodingKeys>, fallback: [BarGesture: BarAction]
    ) -> [BarGesture: BarAction] {
        guard let table = try? c.decodeIfPresent([String: String].self, forKey: .gestures) else {
            return fallback
        }
        var out: [BarGesture: BarAction] = [:]
        for (key, value) in table {
            guard let gesture = BarGesture(rawValue: key), let action = BarAction(rawValue: value),
                action.fitsAGesture
            else { continue }
            out[gesture] = action
        }
        return out
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(position, forKey: .position)
        try c.encode(height, forKey: .height)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(horizontalMargin, forKey: .horizontalMargin)
        try c.encode(verticalOffset, forKey: .verticalOffset)
        try c.encode(isPill, forKey: .isPill)
        try c.encodeIfPresent(fill, forKey: .fill)
        try c.encodeIfPresent(customColor, forKey: .customColor)
        try c.encode(customColorOpacity, forKey: .customColorOpacity)
        try c.encode(blurStrength, forKey: .blurStrength)
        try c.encode(showsBorder, forKey: .showsBorder)
        try c.encode(showsShadow, forKey: .showsShadow)
        try c.encode(urlFontSize, forKey: .urlFontSize)
        try c.encode(accentSource, forKey: .accentSource)
        try c.encodeIfPresent(fixedAccent, forKey: .fixedAccent)
        try c.encode(haptics, forKey: .haptics)
        try c.encode(contents, forKey: .contents)
        try c.encode(leftSlots, forKey: .leftSlots)
        try c.encode(rightSlots, forKey: .rightSlots)
        try c.encode(overflowSlots, forKey: .overflowSlots)
        try c.encode(
            Dictionary(uniqueKeysWithValues: gestures.map { ($0.key.rawValue, $0.value.rawValue) }),
            forKey: .gestures)
        try c.encode(autoHide, forKey: .autoHide)
        try c.encode(landscape, forKey: .landscape)
        try c.encode(presetID, forKey: .presetID)
    }
}

// MARK: - Slots

enum BarSlot: String, CaseIterable, Identifiable, Sendable {
    case left, right, overflow

    var id: String { rawValue }

    /// What the editor calls it. "More menu" rather than "Overflow menu"
    /// because the button it fills is labelled *More* — the editor should name
    /// the thing you can see, not the thing the code calls it (#008AC).
    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .overflow: return "More menu"
        }
    }

    /// For "Move to…" and "Add to…", where the title alone reads oddly.
    var placePhrase: String {
        switch self {
        case .left: return "the left"
        case .right: return "the right"
        case .overflow: return "the More menu"
        }
    }

    var capacity: Int {
        self == .overflow ? BarLayout.maxOverflowItems : BarLayout.maxSlotItems
    }

    /// "3 of 4" — spelled out, because "3/4" reads as three quarters.
    func countLabel(_ used: Int) -> String { "\(used) of \(capacity)" }
}

extension BarLayout {
    /// The actions that are not on the bar anywhere — the library's contents
    /// (#008AC). A library that lists everything cannot answer the question it
    /// exists to answer, which is "where did my Bookmark button go?".
    var unplacedActions: [BarAction] {
        let placed = Set(BarSlot.allCases.flatMap { slots($0).map(\.action) })
        return BarAction.slotLibrary.filter { !placed.contains($0) }
    }
}

// MARK: - Presets

struct BarPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let layout: BarLayout

    static let all: [BarPreset] = [.zen, .safari, .quiche, .minimal]

    static func preset(id: String?) -> BarPreset? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// What the bar has always been: a floating pill, the sidebar button on the
    /// left, bookmark and overflow on the right.
    static let zen = BarPreset(
        id: "zen", name: "Zen", detail: "The floating pill, as it ships.",
        layout: make(id: "zen") { layout in
            layout.position = .bottomFloating
            layout.leftSlots = [BarSlotItem(.sidebar, longPress: .newTab)]
            layout.rightSlots = [
                BarSlotItem(.bookmark, longPress: .history),
                BarSlotItem(.overflowMenu),
            ]
            layout.overflowSlots = [
                BarSlotItem(.reloadStop), BarSlotItem(.share), BarSlotItem(.findInPage),
                BarSlotItem(.desktopSite), BarSlotItem(.splitView), BarSlotItem(.compactToggle),
                BarSlotItem(.focusMode), BarSlotItem(.layoutCycle), BarSlotItem(.passwords),
                BarSlotItem(.history), BarSlotItem(.localServices), BarSlotItem(.settings),
            ]
            layout.gestures = [
                .swipeUp: .sidebar, .swipeDown: .hideBar,
                .swipeLeft: .nextTab, .swipeRight: .previousTab,
                .longPress: .actionMenu, .doubleTap: .reloadStop,
            ]
        })

    /// Safari's shape: docked at the bottom, back/forward at the left, share
    /// and tabs at the right, the page title rather than the bare domain.
    static let safari = BarPreset(
        id: "safari", name: "Safari-like",
        detail: "Docked, back and forward on the left, share and tabs on the right.",
        layout: make(id: "safari") { layout in
            layout.position = .bottomDocked
            layout.isPill = false
            layout.horizontalMargin = 0
            layout.cornerRadius = 0
            layout.contents.label = .domain
            layout.contents.progress = .line
            layout.leftSlots = [BarSlotItem(.back), BarSlotItem(.forward)]
            layout.rightSlots = [
                BarSlotItem(.share), BarSlotItem(.bookmark), BarSlotItem(.sidebar),
                BarSlotItem(.overflowMenu),
            ]
            layout.overflowSlots = [
                BarSlotItem(.reloadStop), BarSlotItem(.findInPage), BarSlotItem(.desktopSite),
                BarSlotItem(.history), BarSlotItem(.settings),
            ]
            layout.gestures = [
                .swipeLeft: .nextTab, .swipeRight: .previousTab,
                .swipeUp: .sidebar, .swipeDown: .hideBar,
                .longPress: .actionMenu, .doubleTap: .scrollToTop,
            ]
        })

    /// Quiche's own default shape as far as one can be read off it: a tall
    /// floating pill with a favicon, the full URL, a fill-behind progress
    /// indicator and reload right there in the bar.
    static let quiche = BarPreset(
        id: "quiche", name: "Quiche-like",
        detail: "A tall floating pill: favicon, full URL, reload in the bar.",
        layout: make(id: "quiche") { layout in
            layout.position = .bottomFloating
            layout.height = BarHeightStep.large.points
            layout.cornerRadius = BarLayout.maxCornerRadius
            layout.horizontalMargin = 16
            layout.verticalOffset = 10
            layout.urlFontSize = 14
            layout.contents = BarContents(
                showsFavicon: true, showsSecurityBadge: true, label: .fullURL,
                progress: .fill, showsFindButton: true)
            layout.leftSlots = [BarSlotItem(.sidebar, longPress: .spaceSwitcher)]
            // Three glyphs plus a favicon, a badge and a find button is as much
            // as fits beside a *full* URL before the URL stops being readable —
            // so the new-tab button lives in the overflow here.
            layout.rightSlots = [
                BarSlotItem(.reloadStop, longPress: .desktopSite),
                BarSlotItem(.overflowMenu),
            ]
            layout.overflowSlots = [
                BarSlotItem(.newTab), BarSlotItem(.share), BarSlotItem(.bookmark),
                BarSlotItem(.copyURL), BarSlotItem(.splitView), BarSlotItem(.glance),
                BarSlotItem(.layoutCycle), BarSlotItem(.compactToggle), BarSlotItem(.focusMode),
                BarSlotItem(.history), BarSlotItem(.localServices), BarSlotItem(.settings),
            ]
            layout.gestures = [
                .swipeLeft: .nextTab, .swipeRight: .previousTab,
                .swipeUp: .omnibox, .swipeDown: .hideBar,
                .longPress: .actionMenu, .doubleTap: .reloadStop,
            ]
            layout.autoHide = .onScroll
        })

    /// Nothing but the address and a way back to the tabs.
    static let minimal = BarPreset(
        id: "minimal", name: "Minimal", detail: "The address, and nothing else.",
        layout: make(id: "minimal") { layout in
            layout.position = .bottomFloating
            layout.height = BarHeightStep.small.points
            layout.horizontalMargin = 28
            layout.urlFontSize = 13
            layout.showsShadow = false
            layout.contents = BarContents(
                showsFavicon: false, showsSecurityBadge: true, label: .domain,
                progress: .none, showsFindButton: false)
            layout.leftSlots = []
            layout.rightSlots = [BarSlotItem(.overflowMenu)]
            layout.overflowSlots = [
                BarSlotItem(.reloadStop), BarSlotItem(.sidebar), BarSlotItem(.newTab),
                BarSlotItem(.share), BarSlotItem(.findInPage), BarSlotItem(.history),
                BarSlotItem(.localServices), BarSlotItem(.settings),
            ]
            layout.gestures = [
                .swipeUp: .sidebar, .swipeDown: .hideBar,
                .swipeLeft: .nextTab, .swipeRight: .previousTab,
                .longPress: .actionMenu, .doubleTap: .reloadStop,
            ]
            layout.autoHide = .onScroll
        })

    /// Build a preset from the bare defaults. `BarLayout.init()` returns the
    /// Zen preset, so presets cannot use it without recursing.
    private static func make(id: String, _ body: (inout BarLayout) -> Void) -> BarLayout {
        var layout = BarLayout(raw: ())
        body(&layout)
        layout.presetID = id
        return layout.normalised()
    }
}
