//  EffectiveDisplayTests.swift
//  Per-space display overrides (#008BB): the precedence, the persistence, and
//  the rule that keeps the feature from quietly having holes in it.
//
//  The last of those is `testNothingReadsTheGlobalsDirectly`, and it is the
//  most valuable test in this file. A view that still reads `settings.layout`
//  keeps working perfectly for anyone who never sets an override, so the bug
//  is invisible until somebody sets one and wonders why *that one screen* did
//  not follow. There is nothing to assert about behaviour there — the thing to
//  assert is that the read does not exist, so this reads the source tree.

import XCTest

@testable import Zen

final class EffectiveDisplayTests: XCTestCase {

    private func space(_ overrides: DisplayOverrides? = nil) -> Space {
        var space = Space(name: "Work", icon: "briefcase.fill", isSymbol: true)
        space.display = overrides
        return space
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    // MARK: Precedence

    func testWithNoOverridesEverythingIsTheGlobal() {
        var settings = ZenSettings()
        settings.layout = .fullScreen
        settings.appearance = .dark
        settings.barFill = .matte
        settings.compactModeEnabled = true
        settings.sidebarEdge = .trailing
        settings.defaultPageZoom = 1.25
        settings.navigationHelperEnabled = true

        let display = EffectiveDisplay.resolve(settings: settings, overrides: nil)
        XCTAssertEqual(display.layout, .fullScreen)
        XCTAssertEqual(display.appearance, .dark)
        XCTAssertEqual(display.barFill, .matte)
        XCTAssertTrue(display.compactModeEnabled)
        XCTAssertEqual(display.sidebarEdge, .trailing)
        XCTAssertEqual(display.textSize, 1.25)
        XCTAssertTrue(display.navigationHelperEnabled)
        XCTAssertEqual(display.barLayout, settings.barLayout)
    }

    func testASpacesOverrideBeatsTheGlobal() {
        var settings = ZenSettings()
        settings.layout = .card
        settings.appearance = .light
        settings.compactModeEnabled = false

        var overrides = DisplayOverrides()
        overrides.layout = .fullScreen
        overrides.appearance = .dark
        overrides.compactModeEnabled = true

        let display = EffectiveDisplay.resolve(settings: settings, overrides: overrides)
        XCTAssertEqual(display.layout, .fullScreen)
        XCTAssertEqual(display.appearance, .dark)
        XCTAssertTrue(display.compactModeEnabled)
    }

    /// Per field, not per struct: overriding the layout must not drag the
    /// appearance along with it.
    func testOverridingOneFieldLeavesTheRestInheriting() {
        var settings = ZenSettings()
        settings.appearance = .sepia
        settings.barFill = .transparent

        var overrides = DisplayOverrides()
        overrides.layout = .edgeToEdge

        let display = EffectiveDisplay.resolve(settings: settings, overrides: overrides)
        XCTAssertEqual(display.layout, .edgeToEdge)
        XCTAssertEqual(display.appearance, .sepia)
        XCTAssertEqual(display.barFill, .transparent)
    }

    /// Inherit is not "the same value as the global right now" — it has to
    /// keep following when the global moves, which is the whole difference.
    func testAnInheritedFieldFollowsTheGlobalWhenItChanges() {
        var settings = ZenSettings()
        let overrides = DisplayOverrides()

        settings.layout = .card
        XCTAssertEqual(EffectiveDisplay.resolve(settings: settings, overrides: overrides).layout, .card)

        settings.layout = .fullScreen
        XCTAssertEqual(
            EffectiveDisplay.resolve(settings: settings, overrides: overrides).layout, .fullScreen)
    }

    /// The false-y trap: `false` is an override, not an absence. A space that
    /// says "compact off" must stay off when the global goes on.
    func testAnExplicitFalseIsStillAnOverride() {
        var settings = ZenSettings()
        settings.compactModeEnabled = true
        settings.navigationHelperEnabled = true

        var overrides = DisplayOverrides()
        overrides.compactModeEnabled = false
        overrides.navigationHelperEnabled = false

        let display = EffectiveDisplay.resolve(settings: settings, overrides: overrides)
        XCTAssertFalse(display.compactModeEnabled)
        XCTAssertFalse(display.navigationHelperEnabled)
    }

    // MARK: The bar

    func testAPresetIdIsEnoughToChangeTheBar() {
        let settings = ZenSettings()
        var overrides = DisplayOverrides()
        overrides.barPresetID = BarPreset.safari.id

        let display = EffectiveDisplay.resolve(settings: settings, overrides: overrides)
        XCTAssertEqual(display.barLayout, BarPreset.safari.layout)
    }

    /// A full layout is the more specific answer, so it wins.
    func testAFullLayoutBeatsAPresetId() {
        let settings = ZenSettings()
        var overrides = DisplayOverrides()
        overrides.barPresetID = BarPreset.safari.id
        overrides.barLayout = BarPreset.minimal.layout

        let display = EffectiveDisplay.resolve(settings: settings, overrides: overrides)
        XCTAssertEqual(display.barLayout, BarPreset.minimal.layout)
    }

    /// A preset that no longer exists must leave the space with the global bar
    /// rather than with no bar at all.
    func testAnUnknownPresetIdFallsThroughToTheGlobal() {
        var settings = ZenSettings()
        settings.barLayout = BarPreset.quiche.layout
        var overrides = DisplayOverrides()
        overrides.barPresetID = "a-preset-from-next-year"

        let display = EffectiveDisplay.resolve(settings: settings, overrides: overrides)
        XCTAssertEqual(display.barLayout, BarPreset.quiche.layout)
    }

    /// The layout may pin a fill; the space's fill is the fallback under it.
    func testTheLayoutsOwnFillStillWins() {
        var settings = ZenSettings()
        settings.barFill = .matte
        var overrides = DisplayOverrides()
        overrides.barFill = .transparent
        var pinned = BarPreset.zen.layout
        pinned.fill = .liquidGlass
        overrides.barLayout = pinned

        let display = EffectiveDisplay.resolve(settings: settings, overrides: overrides)
        XCTAssertEqual(display.barFill, .transparent)
        XCTAssertEqual(display.resolvedBarFill, .liquidGlass)
    }

    // MARK: The navigation helper's side

    /// Automatic follows the *space's* sidebar edge, not the global one — a
    /// space that moved its sidebar would otherwise stack two sets of targets
    /// under the same thumb.
    func testAutomaticFollowsTheSpacesOwnSidebarEdge() {
        var settings = ZenSettings()
        settings.sidebarEdge = .leading
        settings.navigationHelperSide = nil

        var overrides = DisplayOverrides()
        overrides.sidebarEdge = .trailing

        XCTAssertEqual(
            EffectiveDisplay.resolve(settings: settings, overrides: nil).navigationHelperSide,
            .trailing)
        XCTAssertEqual(
            EffectiveDisplay.resolve(settings: settings, overrides: overrides)
                .navigationHelperSide, .leading)
    }

    func testAnExplicitHelperSideIgnoresTheSidebarEntirely() {
        var settings = ZenSettings()
        settings.sidebarEdge = .leading
        settings.navigationHelperSide = .leading
        XCTAssertEqual(
            EffectiveDisplay.resolve(settings: settings, overrides: nil).navigationHelperSide,
            .leading)
    }

    // MARK: Clamping

    func testAHostileTextSizeOverrideIsClamped() {
        var overrides = DisplayOverrides()
        overrides.textSize = 99
        let display = EffectiveDisplay.resolve(settings: ZenSettings(), overrides: overrides)
        XCTAssertEqual(display.textSize, PageZoom.maximum)
    }

    // MARK: isEmpty and the names

    func testEmptyMeansNothingIsOverridden() {
        XCTAssertTrue(DisplayOverrides().isEmpty)
        XCTAssertTrue(DisplayOverrides().overriddenNames.isEmpty)

        var overrides = DisplayOverrides()
        overrides.compactModeEnabled = false
        XCTAssertFalse(overrides.isEmpty, "an explicit false is an override")
        XCTAssertEqual(overrides.overriddenNames, ["Compact mode"])
    }

    func testEveryOverridableFieldHasAName() {
        var overrides = DisplayOverrides()
        overrides.layout = .card
        overrides.appearance = .dark
        overrides.barPresetID = BarPreset.zen.id
        overrides.barFill = .matte
        overrides.compactModeEnabled = true
        overrides.sidebarEdge = .trailing
        overrides.textSize = 1.25
        overrides.navigationHelperEnabled = true
        XCTAssertEqual(
            overrides.overriddenNames,
            [
                "Layout", "Appearance", "Bar layout", "Bar fill", "Compact mode",
                "Sidebar position", "Text size", "Navigation helper",
            ])
    }

    // MARK: Persistence

    func testOverridesRideAlongInTheSpace() throws {
        var overrides = DisplayOverrides()
        overrides.layout = .fullScreen
        overrides.appearance = .sepia
        overrides.barPresetID = BarPreset.minimal.id
        overrides.barFill = .transparent
        overrides.compactModeEnabled = true
        overrides.sidebarEdge = .trailing
        overrides.textSize = 1.5
        overrides.navigationHelperEnabled = true

        let restored = try JSONDecoder().decode(Space.self, from: encoded(space(overrides)))
        XCTAssertEqual(restored.display, overrides)
    }

    func testAFullBarLayoutOverrideSurvivesTheRoundTrip() throws {
        var overrides = DisplayOverrides()
        var layout = BarPreset.quiche.layout
        layout.setRows(.two)
        overrides.barLayout = layout

        let restored = try JSONDecoder().decode(Space.self, from: encoded(space(overrides)))
        XCTAssertEqual(restored.display?.barLayout?.rows, .two)
    }

    /// The thing that would be discovered as "all my spaces came back blank":
    /// a space written before #008BB has no `display` key at all.
    func testASpaceFromBeforeTheFeatureDecodes() throws {
        // Built by encoding a real space and deleting the key, rather than by
        // hand: a hand-written space would have to reproduce `ZenTheme`'s
        // whole shape, and would then be testing that instead.
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded(space(DisplayOverrides())))
                as? [String: Any])
        object.removeValue(forKey: "display")
        XCTAssertNil(object["display"])

        let older = try JSONSerialization.data(withJSONObject: object)
        let space = try JSONDecoder().decode(Space.self, from: older)
        XCTAssertNil(space.display)
        XCTAssertEqual(
            EffectiveDisplay.resolve(settings: ZenSettings(), overrides: space.display).layout,
            ZenSettings().layout)
    }

    /// A value from a newer build must read as "inherit", not throw away the
    /// whole space.
    func testAnUnreadableOverrideReadsAsInherit() throws {
        let json = """
            {"layout":"hologram","appearance":"neon","barFill":"chrome",
             "sidebarEdge":"middle","textSize":"big"}
            """
        let overrides = try JSONDecoder().decode(DisplayOverrides.self, from: Data(json.utf8))
        XCTAssertTrue(overrides.isEmpty)
    }

    func testAnOverrideFileIsClampedOnDecode() throws {
        let overrides = try JSONDecoder().decode(
            DisplayOverrides.self, from: Data(#"{"textSize":40}"#.utf8))
        XCTAssertEqual(overrides.textSize, PageZoom.maximum)
    }

    // MARK: Writing at the level that decides

    @MainActor
    func testTheLayoutCycleEditsTheGlobalWhenTheSpaceInherits() {
        let state = BrowserState(session: SessionStore(), restore: false)
        state.setLayout(.fullScreen)
        XCTAssertEqual(state.settings.layout, .fullScreen)
        XCTAssertNil(state.activeSpace?.display)
    }

    /// …and the space's own when it has one. Otherwise flipping the layout in
    /// a space that overrides it would do nothing visible at all.
    @MainActor
    func testTheLayoutCycleEditsTheSpaceWhenItOverrides() {
        let state = BrowserState(session: SessionStore(), restore: false)
        let spaceID = try? XCTUnwrap(state.activeSpaceID)
        guard let spaceID else { return XCTFail("no active space") }

        var overrides = DisplayOverrides()
        overrides.layout = .card
        state.setDisplayOverrides(overrides, for: spaceID)

        state.setLayout(.edgeToEdge)
        XCTAssertEqual(state.activeSpace?.display?.layout, .edgeToEdge)
        XCTAssertEqual(state.settings.layout, .card, "the global must be left alone")
        XCTAssertEqual(state.display.layout, .edgeToEdge)
    }

    @MainActor
    func testCompactModeFollowsTheSameRule() {
        let state = BrowserState(session: SessionStore(), restore: false)
        let spaceID = try? XCTUnwrap(state.activeSpaceID)
        guard let spaceID else { return XCTFail("no active space") }

        state.setCompactMode(true)
        XCTAssertTrue(state.settings.compactModeEnabled)

        var overrides = DisplayOverrides()
        overrides.compactModeEnabled = false
        state.setDisplayOverrides(overrides, for: spaceID)
        state.setCompactMode(true)
        XCTAssertEqual(state.activeSpace?.display?.compactModeEnabled, true)
    }

    @MainActor
    func testResettingASpacesDisplayClearsItEntirely() {
        let state = BrowserState(session: SessionStore(), restore: false)
        let spaceID = try? XCTUnwrap(state.activeSpaceID)
        guard let spaceID else { return XCTFail("no active space") }

        var overrides = DisplayOverrides()
        overrides.appearance = .dark
        state.setDisplayOverrides(overrides, for: spaceID)
        XCTAssertNotNil(state.activeSpace?.display)

        state.setDisplayOverrides(DisplayOverrides(), for: spaceID)
        XCTAssertNil(
            state.activeSpace?.display,
            "an empty set of overrides should be stored as no overrides at all")
    }

    @MainActor
    func testSwitchingSpacesSwitchesTheWholeResolvedDisplay() {
        let state = BrowserState(session: SessionStore(), restore: false)
        let ids = state.spaces.map(\.id)
        guard ids.count >= 2 else { return XCTFail("need two spaces") }

        var overrides = DisplayOverrides()
        overrides.layout = .fullScreen
        overrides.appearance = .dark
        state.setDisplayOverrides(overrides, for: ids[1])

        state.switchSpace(to: ids[0])
        XCTAssertEqual(state.display.layout, state.settings.layout)

        state.switchSpace(to: ids[1])
        XCTAssertEqual(state.display.layout, .fullScreen)
        XCTAssertEqual(state.display.appearance, .dark)
    }

    // MARK: The rule itself

    /// Every overridable value has exactly one reader: `BrowserState.display`.
    ///
    /// This walks `Sources/` and fails on any direct read of one of the global
    /// keys outside the files that are *allowed* to touch them — the model
    /// that defines them, the accessor that resolves them, and the editors
    /// that write them. A `$state.settings.x` binding is a write and is fine;
    /// a bare read is the hole this exists to stop.
    func testNothingReadsTheGlobalsDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ZenTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ios
            .appendingPathComponent("Sources")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: sources.path),
            "the source tree is not next to the test bundle")

        /// The globals a space may override. Reading one of these outside the
        /// allowed files is the bug.
        let guarded = [
            "layout", "appearance", "barLayout", "barFill", "compactModeEnabled",
            "sidebarEdge", "defaultPageZoom", "navigationHelperEnabled",
        ]
        /// The model that defines them, the accessor that resolves them, and
        /// the screens whose whole job is editing the globals.
        let allowed: Set<String> = [
            "SessionStore.swift", "EffectiveDisplay.swift", "BrowserState.swift",
            "SettingsSheet.swift", "BarCustomizerView.swift", "BarSlotEditor.swift",
            "SpaceEditorView.swift",
        ]

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !allowed.contains($0.lastPathComponent) }
        XCTAssertFalse(files?.isEmpty ?? true, "found no sources to check — the walk is broken")

        var offences: [String] = []
        for file in files ?? [] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                // Comments may name them; the file comments here do.
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                for key in guarded where line.contains("settings.\(key)") {
                    // `$state.settings.x` is a binding — a write, from a screen
                    // that is allowed to write. Only reads are the problem.
                    guard !line.contains("$state.settings.\(key)"),
                        !line.contains("$settings.\(key)")
                    else { continue }
                    offences.append(
                        "\(file.lastPathComponent):\(number + 1) reads settings.\(key)")
                }
            }
        }
        XCTAssertEqual(
            offences, [],
            "read these through `state.display` — a direct read keeps working for anyone with "
                + "no override and silently ignores the ones who have (#008BB)")
    }
}
