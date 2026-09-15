//  HapticsTests.swift
//  Haptic feedback leaves nothing on screen, so a recording backend is the only
//  way to assert on it at all. These tests cover the three things that are easy
//  to get wrong and impossible to notice: the level filter, the suppression
//  rules, and the "at most one per event" coalescing.

import XCTest

@testable import Zen

@MainActor
final class HapticsTests: XCTestCase {

    private var recorder: RecordingHapticBackend!

    override func setUp() {
        super.setUp()
        recorder = RecordingHapticBackend()
    }

    private func haptics(_ level: HapticLevel) -> Haptics {
        let service = Haptics(backend: recorder)
        service.level = level
        return service
    }

    // MARK: The setting

    func testDefaultLevelIsNormal() {
        XCTAssertEqual(ZenSettings().hapticLevel, .normal)
    }

    func testLevelSurvivesASettingsRoundTrip() throws {
        var settings = ZenSettings()
        settings.hapticLevel = .rich
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ZenSettings.self, from: data).hapticLevel, .rich)
    }

    /// A session file written before haptics existed must still decode, and
    /// must land on the default rather than throwing (which SessionStore reads
    /// as "no session" — i.e. everyone's tabs gone).
    func testSettingsWithoutAHapticKeyDecodeToTheDefault() throws {
        let json = Data(#"{"searchEngine":"google","compactModeEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(ZenSettings.self, from: json)
        XCTAssertEqual(settings.hapticLevel, .normal)
        XCTAssertEqual(settings.searchEngine, .google)
    }

    // MARK: The level filter

    func testOffPlaysNothingAtAll() {
        let service = haptics(.off)
        for event in HapticEvent.allCases { service.fire(event) }
        XCTAssertTrue(recorder.played.isEmpty)
    }

    func testSubtleKeepsOnlyTheEssentialTier() {
        let service = haptics(.subtle)
        service.fire(.swipeCloseThreshold)
        service.fire(.tabSelect)
        service.fire(.pageLoaded)
        XCTAssertEqual(recorder.played.count, 1)
        XCTAssertEqual(recorder.played.first, .impact(.rigid, intensity: 0.9 * 0.62))
    }

    func testNormalKeepsEverythingButTheFlourishes() {
        let service = haptics(.normal)
        service.fire(.tabSelect)
        service.fire(.pageLoaded)
        XCTAssertEqual(recorder.played, [.selection])
    }

    func testRichPlaysTheFlourishes() {
        let service = haptics(.rich)
        service.fire(.pageLoaded)
        XCTAssertEqual(recorder.played, [.impact(.light, intensity: 0.3)])
    }

    /// Signatures are a Rich-only texture; every other level feels the plain
    /// impact instead, rather than nothing.
    func testSignaturesDowngradeToTheirFallbackBelowRich() {
        let rich = haptics(.rich)
        XCTAssertEqual(
            rich.resolve(.spaceSettle), .signature(.spaceSettle, fallback: .init(.rigid, 0.8)))

        recorder.reset()
        let normal = haptics(.normal)
        XCTAssertEqual(normal.resolve(.spaceSettle), .impact(.rigid, intensity: 0.8))
    }

    func testIntensityIsScaledByTheLevel() {
        XCTAssertEqual(haptics(.normal).resolve(.tabOpen), .impact(.light, intensity: 0.8))
        XCTAssertEqual(
            haptics(.subtle).resolve(.dragPickup), .impact(.medium, intensity: 0.9 * 0.62))
    }

    /// A notification generator has no intensity to scale, so an error must
    /// still feel like an error at Subtle.
    func testNoticesAreNotScaled() {
        XCTAssertEqual(haptics(.subtle).resolve(.loadError), .notice(.error))
    }

    /// Nothing in the vocabulary may be silently unplayable.
    func testEveryEventResolvesAtRich() {
        let service = haptics(.rich)
        for event in HapticEvent.allCases {
            XCTAssertNotNil(service.resolve(event), "\(event) resolves to nothing")
        }
    }

    // MARK: Suppression

    func testNothingFiresWhileTheAppIsBackgrounded() {
        let service = haptics(.rich)
        service.isForeground = false
        service.fire(.urlCommit)
        XCTAssertTrue(recorder.played.isEmpty)

        service.isForeground = true
        service.fire(.urlCommit)
        XCTAssertEqual(recorder.played.count, 1)
    }

    func testNothingFiresWhileThePageIsScrolling() {
        let service = haptics(.rich)
        service.isScrolling = true
        service.fire(.compactBarShow)
        service.fire(.pageLoaded)
        XCTAssertTrue(recorder.played.isEmpty)

        service.isScrolling = false
        service.fire(.compactBarShow)
        XCTAssertEqual(recorder.played.count, 1)
    }

    // MARK: Coalescing

    func testTheSameEventTwiceInAMomentPlaysOnce() {
        let service = haptics(.normal)
        service.fire(.tabClose)
        service.fire(.tabClose)
        XCTAssertEqual(recorder.played.count, 1)
    }

    /// Coalescing must not swallow a *different* event arriving in the same
    /// frame — a commit followed by a load error is two real things.
    func testDifferentEventsBackToBackBothPlay() {
        let service = haptics(.normal)
        service.fire(.urlCommit)
        service.fire(.loadError)
        XCTAssertEqual(recorder.played, [.impact(.light, intensity: 0.9), .notice(.error)])
    }

    // MARK: Preparing

    func testPrepareWarmsTheGeneratorAndThenThrottles() {
        let service = haptics(.normal)
        service.prepare(.tabSelect)
        service.prepare(.tabSelect)
        XCTAssertEqual(recorder.prepared, [.selection])
    }

    func testPrepareIsSilentWhenTheLevelExcludesTheEvent() {
        let service = haptics(.subtle)
        service.prepare(.pageLoaded)
        XCTAssertTrue(recorder.prepared.isEmpty)
    }

    /// Preparing is about latency, not about being in the foreground — a warm
    /// generator costs nothing if the event never fires.
    func testPreparingABatchWarmsEachDistinctOutputOnce() {
        let service = haptics(.normal)
        service.prepare([.tabSelect, .tabOpen, .tabSelect])
        XCTAssertEqual(recorder.prepared, [.selection, .impact(.light, intensity: 0.8)])
    }
}
