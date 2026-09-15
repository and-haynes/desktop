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
            XCTAssertLessThanOrEqual(layout.leftSlots.count, BarLayout.maxSlotItems, preset.name)
            XCTAssertLessThanOrEqual(layout.rightSlots.count, BarLayout.maxSlotItems, preset.name)
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
