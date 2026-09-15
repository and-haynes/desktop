//  BarLayoutTests.swift
//  The bar layout is the one value the whole customiser writes and the whole
//  chrome reads, and it lives in the session file — so the things worth
//  pinning down are the ones that would be discovered as "all my settings went
//  back to default after an update".

import XCTest

@testable import Zen

final class BarLayoutTests: XCTestCase {

    private func encoded(_ layout: BarLayout) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(layout)
    }

    private func decoded(_ json: String) throws -> BarLayout {
        try JSONDecoder().decode(BarLayout.self, from: Data(json.utf8))
    }

    // MARK: Round trip

    func testAnEditedLayoutSurvivesARoundTrip() throws {
        var layout = BarPreset.quiche.layout
        layout.position = .topDocked
        layout.height = 52
        layout.cornerRadius = 9
        layout.horizontalMargin = 3
        layout.verticalOffset = 7
        layout.isPill = false
        layout.fill = .matte
        layout.customColor = ZenColor(hex: "#112233")
        layout.customColorOpacity = 0.4
        layout.blurStrength = 0.25
        layout.showsBorder = false
        layout.showsShadow = false
        layout.urlFontSize = 17
        layout.accentSource = .fixed
        layout.fixedAccent = ZenColor(hex: "#AA00FF")
        layout.haptics = false
        layout.contents = BarContents(
            showsFavicon: true, showsSecurityBadge: false, label: .pageTitle,
            progress: .fill, showsFindButton: true)
        layout.autoHide = .onScroll
        layout.landscape = BarLandscapeOverride(position: .bottomDocked, autoHide: .never)
        layout.setGesture(.copyURL, for: .doubleTap)

        let restored = try JSONDecoder().decode(BarLayout.self, from: encoded(layout))
        XCTAssertEqual(restored, layout.normalised())
    }

    func testEveryPresetRoundTrips() throws {
        for preset in BarPreset.all {
            let restored = try JSONDecoder().decode(BarLayout.self, from: encoded(preset.layout))
            XCTAssertEqual(restored, preset.layout, "\(preset.name) did not survive a round trip")
        }
    }

    /// Gestures encode as a plain `{ "swipeUp": "sidebar" }` object rather than
    /// Codable's array-of-pairs, so an exported layout can be hand-edited.
    func testGesturesEncodeAsAReadableObject() throws {
        var layout = BarPreset.zen.layout
        layout.gestures = [.swipeUp: .sidebar]
        let json = try XCTUnwrap(String(data: encoded(layout), encoding: .utf8))
        XCTAssertTrue(json.contains("\"swipeUp\":\"sidebar\""), json)
    }

    // MARK: Forward-compatible decoding

    /// The failure this prevents: adding a field makes every existing session
    /// file undecodable, `SessionStore.load()` reads that as "no session", and
    /// everyone loses their tabs.
    func testAnEmptyDocumentDecodesToTheDefault() throws {
        XCTAssertEqual(try decoded("{}"), BarPreset.zen.layout)
    }

    func testMissingKeysTakeTheirDefaults() throws {
        let layout = try decoded(#"{"height":56,"isPill":false}"#)
        XCTAssertEqual(layout.height, 56)
        XCTAssertFalse(layout.isPill)
        XCTAssertEqual(layout.position, BarPreset.zen.layout.position)
        XCTAssertEqual(layout.contents, BarPreset.zen.layout.contents)
    }

    func testUnknownKeysAreIgnored() throws {
        let layout = try decoded(#"{"height":44,"glitterMode":true,"nested":{"a":[1,2]}}"#)
        XCTAssertEqual(layout.height, 44)
    }

    /// A file written by a *newer* build names values this one has never heard
    /// of. Losing the whole layout over one of them would be the worst possible
    /// answer; losing that one field is the right one.
    func testAnUnknownEnumValueFallsBackWithoutLosingTheRest() throws {
        let layout = try decoded(
            #"{"position":"floatingLeft","height":51,"autoHide":"onShake"}"#)
        XCTAssertEqual(layout.position, BarPreset.zen.layout.position)
        XCTAssertEqual(layout.autoHide, BarPreset.zen.layout.autoHide)
        XCTAssertEqual(layout.height, 51, "the fields this build understands must survive")
    }

    func testAnUnknownGestureOrActionIsDropped() throws {
        let layout = try decoded(
            #"{"gestures":{"swipeUp":"sidebar","swipeSideways":"back","swipeDown":"teleport"}}"#)
        XCTAssertEqual(layout.gestures[.swipeUp], .sidebar)
        XCTAssertNil(layout.gestures[.swipeDown])
        XCTAssertEqual(layout.gestures.count, 1)
    }

    func testAnUnknownSlotActionIsDroppedButTheSlotSurvives() throws {
        let layout = try decoded(
            """
            {"leftSlots":[{"action":"sidebar"},{"action":"summonRaven"},{"action":"back"}]}
            """)
        XCTAssertEqual(layout.leftSlots.map(\.action), [.sidebar, .back])
    }

    /// A hand-edited or hostile file must not produce a 4000pt bar.
    func testValuesAreClampedOnDecode() throws {
        let layout = try decoded(
            #"{"height":4000,"cornerRadius":-20,"blurStrength":9,"urlFontSize":900}"#)
        XCTAssertEqual(layout.height, BarLayout.maxHeight)
        XCTAssertEqual(layout.cornerRadius, 0)
        XCTAssertEqual(layout.blurStrength, 1)
        XCTAssertEqual(layout.urlFontSize, BarLayout.maxURLFontSize)
    }

    /// `ZenSettings` must keep its own tabs-preserving contract: a session file
    /// with no `barLayout` at all is an older file, not a broken one.
    func testSettingsWithoutABarLayoutStillDecode() throws {
        let settings = try JSONDecoder().decode(
            ZenSettings.self, from: Data(#"{"searchEngine":"google"}"#.utf8))
        XCTAssertEqual(settings.searchEngine, .google)
        XCTAssertEqual(settings.barLayout, BarPreset.zen.layout)
    }

    func testSettingsWithAnUnreadableBarLayoutStillDecode() throws {
        let settings = try JSONDecoder().decode(
            ZenSettings.self, from: Data(#"{"showStatusBar":true,"barLayout":"nonsense"}"#.utf8))
        XCTAssertTrue(settings.showStatusBar)
        XCTAssertEqual(settings.barLayout, BarPreset.zen.layout)
    }

    // MARK: Slots

    func testASlotRefusesMoreThanItsCapacity() {
        var layout = BarPreset.minimal.layout
        layout.leftSlots = []
        for _ in 0..<BarLayout.maxSlotItems {
            XCTAssertTrue(layout.add(.back, to: .left))
        }
        XCTAssertFalse(layout.add(.forward, to: .left), "the slot must refuse, not silently drop")
        XCTAssertEqual(layout.leftSlots.count, BarLayout.maxSlotItems)
    }

    func testTheOverflowSlotHoldsMore() {
        var layout = BarPreset.zen.layout
        layout.overflowSlots = []
        for _ in 0..<BarLayout.maxOverflowItems {
            XCTAssertTrue(layout.add(.share, to: .overflow))
        }
        XCTAssertFalse(layout.add(.share, to: .overflow))
        XCTAssertEqual(layout.overflowSlots.count, BarLayout.maxOverflowItems)
    }

    func testAGestureOnlyActionCannotSitInASlot() {
        var layout = BarPreset.zen.layout
        XCTAssertFalse(layout.add(.hideBar, to: .left))
        XCTAssertFalse(layout.add(.nextTab, to: .right))
        XCTAssertFalse(layout.add(.actionMenu, to: .overflow))
    }

    func testMovingWithinAFullSlotIsAllowed() {
        var layout = BarPreset.zen.layout
        layout.rightSlots = []
        for _ in 0..<BarLayout.maxSlotItems { _ = layout.add(.share, to: .right) }
        let last = try? XCTUnwrap(layout.rightSlots.last)
        guard let last else { return XCTFail("no item") }
        XCTAssertTrue(
            layout.move(last.id, to: .right, at: 0),
            "reordering inside a full slot adds nothing to it")
        XCTAssertEqual(layout.rightSlots.first?.id, last.id)
    }

    func testMovingIntoAFullSlotIsRefused() {
        var layout = BarPreset.zen.layout
        layout.leftSlots = [BarSlotItem(.back)]
        layout.rightSlots = []
        for _ in 0..<BarLayout.maxSlotItems { _ = layout.add(.share, to: .right) }
        let item = layout.leftSlots[0]
        XCTAssertFalse(layout.move(item.id, to: .right, at: 0))
        XCTAssertEqual(layout.leftSlots.count, 1, "a refused move must not lose the item")
    }

    func testMovingBetweenSlotsKeepsTheLongPress() {
        var layout = BarPreset.zen.layout
        layout.leftSlots = [BarSlotItem(.sidebar, longPress: .newTab)]
        layout.rightSlots = []
        let item = layout.leftSlots[0]
        XCTAssertTrue(layout.move(item.id, to: .right, at: 0))
        XCTAssertTrue(layout.leftSlots.isEmpty)
        XCTAssertEqual(layout.rightSlots.first?.longPress, .newTab)
    }

    func testRemovingTakesItFromWhicheverSlotHoldsIt() {
        var layout = BarPreset.zen.layout
        let item = try? XCTUnwrap(layout.overflowSlots.first)
        guard let item else { return XCTFail("no overflow items") }
        layout.remove(item.id)
        XCTAssertNil(layout.item(item.id))
    }

    func testNormalisingTrimsAnOverfilledSlot() {
        var layout = BarPreset.zen.layout
        layout.leftSlots = Array(repeating: BarSlotItem(.back), count: 12)
        XCTAssertEqual(layout.normalised().leftSlots.count, BarLayout.maxSlotItems)
    }

    // MARK: Presets

    func testEveryPresetIsWithinItsOwnLimits() {
        for preset in BarPreset.all {
            let layout = preset.layout
            XCTAssertLessThanOrEqual(layout.leftSlots.count, layout.capacity(.left), preset.name)
            XCTAssertLessThanOrEqual(layout.rightSlots.count, layout.capacity(.right), preset.name)
            XCTAssertLessThanOrEqual(
                layout.overflowSlots.count, BarLayout.maxOverflowItems, preset.name)
            XCTAssertEqual(layout, layout.normalised(), "\(preset.name) is not normalised")
        }
    }

    func testEveryPresetCanStillReachSettings() {
        // A preset that customised away every route into Settings would be a
        // bar you cannot get out of.
        for preset in BarPreset.all {
            let reachable =
                preset.layout.leftSlots + preset.layout.rightSlots + preset.layout.overflowSlots
            XCTAssertTrue(
                reachable.contains { $0.action == .settings }
                    || reachable.contains { $0.action == .overflowMenu },
                "\(preset.name) has no way back to Settings")
        }
    }

    func testApplyingAPresetIsIdentifiedAsThatPreset() {
        for preset in BarPreset.all {
            XCTAssertEqual(preset.layout.presetID, preset.id)
            XCTAssertEqual(BarPreset.preset(id: preset.layout.presetID)?.id, preset.id)
        }
    }

    /// Editing a preset stops it being that preset — otherwise "reset to
    /// preset" would claim to undo changes it has already absorbed.
    func testEditingAPresetClearsItsIdentity() {
        var layout = BarPreset.safari.layout
        XCTAssertEqual(layout.presetID, "safari")
        _ = layout.add(.glance, to: .overflow)
        XCTAssertNil(layout.presetID)

        var second = BarPreset.safari.layout
        second.setGesture(.copyURL, for: .doubleTap)
        XCTAssertNil(second.presetID)
    }

    func testTheDefaultLayoutIsTheZenPreset() {
        XCTAssertEqual(BarLayout(), BarPreset.zen.layout)
        XCTAssertEqual(ZenSettings().barLayout, BarPreset.zen.layout)
    }

    // MARK: Resolution

    func testTheGlobalBarFillIsUsedUnlessThePresetPinsOne() {
        var layout = BarPreset.zen.layout
        XCTAssertNil(layout.fill)
        XCTAssertEqual(layout.resolvedFill(default: .matte), .matte)
        layout.fill = .transparent
        XCTAssertEqual(layout.resolvedFill(default: .matte), .transparent)
    }

    func testLandscapeOverridesOnlyApplyInLandscape() {
        var layout = BarPreset.zen.layout
        layout.position = .bottomFloating
        layout.autoHide = .never
        layout.landscape = BarLandscapeOverride(position: .topDocked, autoHide: .onScroll)

        XCTAssertEqual(layout.position(landscape: false), .bottomFloating)
        XCTAssertEqual(layout.autoHide(landscape: false), .never)
        XCTAssertEqual(layout.position(landscape: true), .topDocked)
        XCTAssertEqual(layout.autoHide(landscape: true), .onScroll)
    }

    func testAnAbsentLandscapeOverrideFallsThrough() {
        var layout = BarPreset.zen.layout
        layout.position = .bottomDocked
        layout.landscape = BarLandscapeOverride(position: nil, autoHide: .compact)
        XCTAssertEqual(layout.position(landscape: true), .bottomDocked)
        XCTAssertEqual(layout.autoHide(landscape: true), .compact)
    }

    // MARK: The action library

    func testTheTwoLibrariesAgreeWithTheirPredicates() {
        XCTAssertEqual(BarAction.slotLibrary, BarAction.allCases.filter(\.fitsASlot))
        XCTAssertEqual(BarAction.gestureLibrary, BarAction.allCases.filter(\.fitsAGesture))
        XCTAssertFalse(BarAction.slotLibrary.contains(.none))
        XCTAssertTrue(BarAction.gestureLibrary.contains(.hideBar))
        XCTAssertFalse(
            BarAction.gestureLibrary.contains(.overflowMenu),
            "a swipe has nothing to anchor a popover to")
    }

    func testEveryActionHasATitleAndASymbol() {
        for action in BarAction.allCases {
            XCTAssertFalse(action.title.isEmpty, "\(action) has no title")
            XCTAssertFalse(action.symbol.isEmpty, "\(action) has no symbol")
        }
    }

    func testTheStatefulGlyphsChange() {
        XCTAssertEqual(
            BarAction.reloadStop.symbol(isLoading: false, isBookmarked: false), "arrow.clockwise")
        XCTAssertEqual(BarAction.reloadStop.symbol(isLoading: true, isBookmarked: false), "xmark")
        XCTAssertEqual(
            BarAction.bookmark.symbol(isLoading: false, isBookmarked: true), "bookmark.fill")
    }

    func testEveryGestureDirectionHasAGestureCase() {
        for direction in BarSwipeDirection.allCases {
            XCTAssertNotNil(BarGesture(direction: direction))
        }
    }

    // MARK: Saved presets

    @MainActor
    func testSavingAPresetTwiceUnderOneNameReplacesIt() throws {
        let store = BarPresetStore(file: JSONFileStore(url: temporaryFile()))
        store.save(BarPreset.zen.layout, as: "Mine")
        var edited = BarPreset.zen.layout
        edited.height = 60
        store.save(edited, as: "mine")
        XCTAssertEqual(store.presets.count, 1)
        XCTAssertEqual(store.presets.first?.layout.height, 60)
    }

    /// A saved preset must not claim to be the built-in it started from, or
    /// "reset to preset" would go somewhere other than the name on the chip.
    @MainActor
    func testASavedPresetLosesTheBuiltInIdentity() {
        let store = BarPresetStore(file: JSONFileStore(url: temporaryFile()))
        store.save(BarPreset.quiche.layout, as: "Mine")
        XCTAssertNil(store.presets.first?.layout.presetID)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-tests-\(UUID().uuidString).json")
    }
}

/// Removing, adding and moving — the verbs #008AC made visible in the editor.
/// The model already had them; what it did not have was a test that pins what
/// "removed" means (back in the library, not gone) or that a move past the
/// limit is refused rather than silently dropping a button.
final class BarSlotMutationTests: XCTestCase {

    private func zen() -> BarLayout { BarPreset.zen.layout }

    // MARK: Remove

    /// Andy's actual complaint: he could not take Bookmark off the bar. So the
    /// first thing to pin is that taking it off works and puts it somewhere he
    /// can find it again.
    func testRemovingBookmarkTakesItOffTheBarAndPutsItInTheLibrary() throws {
        var layout = zen()
        let bookmark = try XCTUnwrap(
            layout.rightSlots.first { $0.action == .bookmark },
            "the Zen preset should ship a Bookmark button on the right")
        XCTAssertFalse(layout.unplacedActions.contains(.bookmark))

        layout.remove(bookmark.id)

        XCTAssertFalse(layout.rightSlots.contains { $0.action == .bookmark })
        XCTAssertNil(layout.slot(containing: bookmark.id))
        XCTAssertTrue(
            layout.unplacedActions.contains(.bookmark),
            "a removed button has to be findable again, or it reads as destroyed")
    }

    /// Removing is an edit, so the layout stops claiming to be the preset.
    func testRemovingClearsThePresetMarker() throws {
        var layout = zen()
        XCTAssertEqual(layout.presetID, "zen")
        layout.remove(try XCTUnwrap(layout.rightSlots.first).id)
        XCTAssertNil(layout.presetID)
    }

    func testRemovingSomethingThatIsNotThereChangesNothingButTheMarker() {
        var layout = zen()
        let before = layout.leftSlots + layout.rightSlots + layout.overflowSlots
        layout.remove(UUID())
        XCTAssertEqual(layout.leftSlots + layout.rightSlots + layout.overflowSlots, before)
    }

    // MARK: Add

    func testAddingPutsAnActionInTheSlotAndTakesItOutOfTheLibrary() {
        var layout = BarLayout()
        layout.leftSlots = []
        layout.rightSlots = []
        layout.overflowSlots = []
        XCTAssertTrue(layout.unplacedActions.contains(.focusMode))

        XCTAssertTrue(layout.add(.focusMode, to: .left))

        XCTAssertEqual(layout.leftSlots.map(\.action), [.focusMode])
        XCTAssertFalse(layout.unplacedActions.contains(.focusMode))
    }

    /// A slot holds four. The fifth is refused rather than silently dropped —
    /// the editor turns that `false` into the say-why.
    func testAddingPastTheLimitIsRefused() {
        var layout = BarLayout()
        layout.leftSlots = []
        let fillers: [BarAction] = [.back, .forward, .reloadStop, .share, .bookmark]
        for action in fillers.prefix(BarLayout.maxSlotItems) {
            XCTAssertTrue(layout.add(action, to: .left))
        }
        XCTAssertFalse(layout.canAdd(to: .left))
        XCTAssertFalse(layout.add(.copyURL, to: .left), "a full slot must refuse")
        XCTAssertEqual(layout.leftSlots.count, BarLayout.maxSlotItems)
    }

    /// The bar-only verbs are not buttons and never become them.
    func testAnActionThatIsNotAButtonCannotBeAdded() {
        var layout = BarLayout()
        for action in [BarAction.hideBar, .omnibox, .actionMenu, .none] {
            XCTAssertFalse(layout.add(action, to: .overflow), "\(action) is not a button")
            XCTAssertFalse(layout.unplacedActions.contains(action))
        }
    }

    // MARK: Move within a slot

    func testReorderingWithinASlot() {
        var layout = BarLayout()
        layout.leftSlots = []
        for action in [BarAction.back, .forward, .reloadStop] {
            XCTAssertTrue(layout.add(action, to: .left))
        }
        let forward = layout.leftSlots[1].id
        XCTAssertTrue(layout.move(forward, to: .left, at: 0))
        XCTAssertEqual(layout.leftSlots.map(\.action), [.forward, .back, .reloadStop])
    }

    /// Reordering inside a *full* slot is still allowed: nothing is being
    /// added, so the capacity check must not fire.
    func testReorderingInsideAFullSlotIsAllowed() {
        var layout = BarLayout()
        layout.leftSlots = []
        for action in [BarAction.back, .forward, .reloadStop, .share] {
            XCTAssertTrue(layout.add(action, to: .left))
        }
        XCTAssertFalse(layout.canAdd(to: .left))
        let last = layout.leftSlots[3].id
        XCTAssertTrue(layout.move(last, to: .left, at: 0), "a full slot can still be reordered")
        XCTAssertEqual(layout.leftSlots.first?.action, .share)
        XCTAssertEqual(layout.leftSlots.count, 4)
    }

    func testAnIndexPastTheEndClampsToTheEnd() {
        var layout = BarLayout()
        layout.leftSlots = []
        for action in [BarAction.back, .forward] { XCTAssertTrue(layout.add(action, to: .left)) }
        let back = layout.leftSlots[0].id
        XCTAssertTrue(layout.move(back, to: .left, at: 99))
        XCTAssertEqual(layout.leftSlots.map(\.action), [.forward, .back])
    }

    // MARK: Move between slots

    func testMovingShareFromTheRightToTheLeft() {
        var layout = BarLayout()
        layout.leftSlots = []
        layout.rightSlots = []
        XCTAssertTrue(layout.add(.share, to: .right))
        let share = layout.rightSlots[0].id

        XCTAssertTrue(layout.move(share, to: .left, at: 0))
        XCTAssertEqual(layout.leftSlots.map(\.action), [.share])
        XCTAssertTrue(layout.rightSlots.isEmpty)
        // It moved; it did not get cloned.
        XCTAssertEqual(layout.slot(containing: share), .left)
    }

    func testMovingIntoAFullSlotIsRefusedAndLeavesTheItemWhereItWas() {
        var layout = BarLayout()
        layout.leftSlots = []
        layout.rightSlots = []
        for action in [BarAction.back, .forward, .reloadStop, .bookmark] {
            XCTAssertTrue(layout.add(action, to: .left))
        }
        XCTAssertTrue(layout.add(.share, to: .right))
        let share = layout.rightSlots[0].id

        XCTAssertFalse(layout.move(share, to: .left, at: 0), "the left slot is full")
        XCTAssertEqual(layout.slot(containing: share), .right, "a refused move must not lose it")
        XCTAssertEqual(layout.leftSlots.count, BarLayout.maxSlotItems)
    }

    func testMovingSomethingThatDoesNotExistIsRefused() {
        var layout = zen()
        XCTAssertFalse(layout.move(UUID(), to: .left, at: 0))
    }

    // MARK: The library

    func testTheLibraryIsExactlyWhatIsNotOnTheBar() {
        let layout = zen()
        let placed = Set(
            (layout.leftSlots + layout.rightSlots + layout.overflowSlots).map(\.action))
        for action in BarAction.slotLibrary {
            XCTAssertEqual(
                layout.unplacedActions.contains(action), !placed.contains(action),
                "\(action) should be in the library exactly when it is off the bar")
        }
    }

    /// The same action in two slots is legal — `BarSlotItem` has its own
    /// identity for exactly that — and it is placed either way.
    func testAnActionPlacedTwiceIsStillOutOfTheLibrary() {
        var layout = BarLayout()
        layout.leftSlots = []
        layout.rightSlots = []
        layout.overflowSlots = []
        XCTAssertTrue(layout.add(.share, to: .left))
        XCTAssertTrue(layout.add(.share, to: .right))
        XCTAssertFalse(layout.unplacedActions.contains(.share))
    }

    // MARK: Round trip

    /// The order has to survive being written down, or every edit is undone by
    /// the next launch.
    func testAnEditedOrderRoundTripsThroughJSON() throws {
        var layout = zen()
        let bookmark = try XCTUnwrap(layout.rightSlots.first { $0.action == .bookmark })
        layout.remove(bookmark.id)
        XCTAssertTrue(layout.add(.focusMode, to: .left))
        let sidebar = try XCTUnwrap(layout.leftSlots.first { $0.action == .sidebar })
        XCTAssertTrue(layout.move(sidebar.id, to: .left, at: 1))

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(BarLayout.self, from: data)

        XCTAssertEqual(decoded.leftSlots.map(\.action), layout.leftSlots.map(\.action))
        XCTAssertEqual(decoded.rightSlots.map(\.action), layout.rightSlots.map(\.action))
        XCTAssertEqual(decoded.overflowSlots.map(\.action), layout.overflowSlots.map(\.action))
        XCTAssertFalse(decoded.rightSlots.contains { $0.action == .bookmark })
        XCTAssertNil(decoded.presetID, "an edited layout is not the preset any more")
    }

    // MARK: Vocabulary the editor shows

    func testTheSlotHeadersAreWhatTheUserSees() {
        XCTAssertEqual(BarSlot.left.title, "Left")
        XCTAssertEqual(BarSlot.right.title, "Right")
        XCTAssertEqual(
            BarSlot.overflow.title, "More menu",
            "the button is labelled More, so the editor should say More")
        XCTAssertEqual(BarSlot.left.countLabel(3, rows: .one), "3 of 4")
        XCTAssertEqual(
            BarSlot.left.countLabel(3, rows: .two), "3 of 7",
            "a side on its own line holds more, and the header has to say so")
    }

    /// Pop out video joined the library with the video work (#008B0), so it can
    /// be put on a slot, a long press or a gesture like anything else.
    func testPopOutVideoIsInTheLibrary() {
        XCTAssertTrue(BarAction.slotLibrary.contains(.popOutVideo))
        XCTAssertTrue(BarAction.gestureLibrary.contains(.popOutVideo))
        XCTAssertEqual(BarAction.popOutVideo.group, .page)
    }
}

/// The two-line stacked bar (#008BA).
///
/// The row count is not a cosmetic flag: it changes how many buttons a slot
/// holds and how much of the screen the bar takes, and both of those are read
/// by code that has no idea it is looking at a two-row bar — the page's scroll
/// insets, the editor's "3 of 4". Those are what this pins, plus the one
/// destructive case: dropping back to one row with seven buttons on a side.
final class BarRowsTests: XCTestCase {

    private func encoded(_ layout: BarLayout) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(layout)
    }

    // MARK: Slot limits

    func testASideHoldsMoreOnItsOwnLine() {
        XCTAssertEqual(BarRows.one.slotCapacity, 4)
        XCTAssertEqual(BarRows.two.slotCapacity, 7)
        XCTAssertEqual(BarSlot.left.capacity(rows: .one), 4)
        XCTAssertEqual(BarSlot.right.capacity(rows: .two), 7)
    }

    /// The More menu is a list; a second row of *buttons* tells it nothing.
    func testTheOverflowMenuDoesNotCareAboutRows() {
        for rows in BarRows.allCases {
            XCTAssertEqual(BarSlot.overflow.capacity(rows: rows), BarLayout.maxOverflowItems)
        }
    }

    func testTwoRowsLetsYouAddPastTheOneRowLimit() {
        var layout = BarPreset.zen.layout
        layout.leftSlots = []
        layout.setRows(.two)
        for _ in 0..<BarRows.two.slotCapacity {
            XCTAssertTrue(layout.add(.share, to: .left))
        }
        XCTAssertFalse(layout.add(.share, to: .left), "the seventh is the last")
        XCTAssertEqual(layout.leftSlots.count, 7)
    }

    func testNormalisingTrimsToTheRowCountsOwnLimit() {
        var layout = BarPreset.zen.layout
        layout.rows = .two
        layout.leftSlots = Array(repeating: BarSlotItem(.back), count: 20)
        XCTAssertEqual(layout.normalised().leftSlots.count, 7)

        layout.rows = .one
        XCTAssertEqual(layout.normalised().leftSlots.count, 4)
    }

    // MARK: Going back to one row

    /// Silently deleting three buttons would be the worst kind of surprise —
    /// you find out by looking for one that is not there. They go to the More
    /// menu, in order, instead.
    func testDroppingToOneRowMovesTheButtonsThatNoLongerFit() {
        var layout = BarPreset.zen.layout
        layout.leftSlots = []
        layout.overflowSlots = []
        layout.setRows(.two)
        let actions: [BarAction] = [
            .back, .forward, .reloadStop, .share, .bookmark, .copyURL, .findInPage,
        ]
        for action in actions { XCTAssertTrue(layout.add(action, to: .left)) }

        layout.setRows(.one)
        XCTAssertEqual(layout.leftSlots.map(\.action), [.back, .forward, .reloadStop, .share])
        XCTAssertEqual(
            layout.overflowSlots.map(\.action), [.bookmark, .copyURL, .findInPage],
            "the displaced buttons should be in the More menu, in the order they were on the bar")
    }

    func testDroppingToOneRowIsANoOpWhenEverythingAlreadyFits() {
        var layout = BarPreset.zen.layout
        layout.setRows(.two)
        let before = layout.overflowSlots
        layout.setRows(.one)
        XCTAssertEqual(layout.overflowSlots, before)
    }

    func testSettingTheSameRowCountChangesNothing() {
        var layout = BarPreset.quiche.layout
        let before = layout
        layout.setRows(.one)
        XCTAssertEqual(layout, before, "including the preset marker")
    }

    // MARK: Height

    func testTwoRowsIsTallerByTheButtonLine() {
        var layout = BarPreset.zen.layout
        layout.height = 48
        XCTAssertEqual(layout.totalHeight(rows: .one), 48)
        XCTAssertEqual(layout.buttonRowHeight(rows: .one), 0)

        let expected = 48 + 48 * BarLayout.stackedButtonRowFactor + BarLayout.stackedRowSpacing
        XCTAssertEqual(layout.totalHeight(rows: .two), expected, accuracy: 0.001)
        XCTAssertGreaterThan(layout.totalHeight(rows: .two), layout.totalHeight(rows: .one))
    }

    // MARK: Landscape

    func testLandscapeCanCollapseBackToOneRow() {
        var layout = BarPreset.zen.layout
        layout.rows = .two
        layout.landscape = BarLandscapeOverride(rows: .one)
        XCTAssertEqual(layout.rows(landscape: false), .two)
        XCTAssertEqual(layout.rows(landscape: true), .one)
    }

    func testWithNoLandscapeOverrideBothOrientationsAgree() {
        var layout = BarPreset.zen.layout
        layout.rows = .two
        XCTAssertEqual(layout.rows(landscape: true), .two)
        XCTAssertFalse(layout.landscape.isEmpty == false, "no override means empty")
    }

    // MARK: Codable

    func testTheRowCountSurvivesARoundTrip() throws {
        var layout = BarPreset.zen.layout
        layout.setRows(.two)
        layout.landscape = BarLandscapeOverride(position: .bottomDocked, rows: .one)
        let restored = try JSONDecoder().decode(BarLayout.self, from: encoded(layout))
        XCTAssertEqual(restored.rows, .two)
        XCTAssertEqual(restored.landscape.rows, .one)
        XCTAssertEqual(restored, layout.normalised())
    }

    /// The thing that would be discovered as "my bar got taller after an
    /// update": a file written before #008BA has no `rows` key at all.
    func testALayoutFromBeforeTheOptionReadsAsOneRow() throws {
        let json = """
            {"version":1,"position":"bottomFloating","height":48,"isPill":true}
            """
        let layout = try JSONDecoder().decode(BarLayout.self, from: Data(json.utf8))
        XCTAssertEqual(layout.rows, .one)
        XCTAssertNil(layout.landscape.rows)
        XCTAssertEqual(layout.totalHeight(rows: layout.rows), 48)
    }

    func testAnUnreadableRowCountFallsBackRatherThanThrowing() throws {
        let json = """
            {"version":1,"rows":"three","landscape":{"rows":99}}
            """
        let layout = try JSONDecoder().decode(BarLayout.self, from: Data(json.utf8))
        XCTAssertEqual(layout.rows, .one)
        XCTAssertNil(layout.landscape.rows)
    }

    func testTheRowCountIsWrittenAsANumber() throws {
        var layout = BarPreset.zen.layout
        layout.setRows(.two)
        let json = try XCTUnwrap(String(data: encoded(layout), encoding: .utf8))
        XCTAssertTrue(json.contains("\"rows\":2"), "rows should read as a line count: \(json)")
    }

    // MARK: The preset

    func testTheStackedPresetIsTwoRowsAndUsesTheRoom() {
        let preset = BarPreset.stacked.layout
        XCTAssertEqual(preset.rows, .two)
        XCTAssertGreaterThan(preset.leftSlots.count, BarLayout.maxSlotItems - 1)
        XCTAssertEqual(preset.landscape.rows, .one, "landscape has the width already")
        XCTAssertEqual(preset, preset.normalised())
    }

    func testEditingTheRowCountClearsThePresetMarker() {
        var layout = BarPreset.zen.layout
        XCTAssertEqual(layout.presetID, "zen")
        layout.setRows(.two)
        XCTAssertNil(layout.presetID)
    }
}
