//  FocusModeTests.swift
//  Focus mode's promises (#00888).
//
//  Focus makes three claims: nothing is written down, erase really erases, and
//  trackers are blocked. The first two are testable here directly; the third is
//  tested to the boundary — that the blocklist we ship is well-formed and the
//  rules say what we think they say. Whether WebKit then enforces them is
//  WebKit's contract, and compiling it needs a real WKContentRuleListStore.

import XCTest
import WebKit

@testable import Zen

@MainActor
final class FocusModeTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenFocus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeState(restore: Bool = false) -> BrowserState {
        BrowserState(
            session: SessionStore(
                file: JSONFileStore<SessionSnapshot>(name: "session.json", directory: directory),
                debounceInterval: 60),
            history: HistoryStore(
                file: JSONFileStore<[HistoryEntry]>(name: "history.json", directory: directory)),
            bookmarks: BookmarkStore(
                file: JSONFileStore<[Bookmark]>(name: "bookmarks.json", directory: directory)),
            trustedCertificates: TrustedCertificateStore(
                file: JSONFileStore<[TrustedCertificate]>(
                    name: "certs.json", directory: directory)),
            restore: restore)
    }

    private func url(_ n: Int) -> URL { URL(string: "https://site\(n).example")! }

    // MARK: Entering and leaving

    func testEnteringFocusCreatesAnEphemeralSpaceWithATab() {
        let state = makeState()
        XCTAssertFalse(state.isFocusMode)
        let before = state.activeSpaceID

        let focus = state.enterFocusMode()
        XCTAssertNotNil(focus)
        XCTAssertTrue(state.isFocusMode)
        XCTAssertEqual(state.activeSpaceID, focus?.id)
        XCTAssertNotEqual(state.activeSpaceID, before)
        XCTAssertNotNil(state.activeTab, "Focus should open on a tab")
        XCTAssertTrue(state.isEphemeral(focus?.id))
        XCTAssertFalse(state.isEphemeral(before))
    }

    func testEnteringTwiceIsANoOp() {
        let state = makeState()
        let first = state.enterFocusMode()
        let second = state.enterFocusMode()
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(state.spaces.filter { $0.id == first?.id }.count, 1)
    }

    func testLeavingFocusReturnsToThePreviousSpaceAndRemovesEverything() {
        let state = makeState()
        let before = state.activeSpaceID
        let focus = state.enterFocusMode()!
        state.newTab(url: url(1))
        state.newTab(url: url(2))

        state.exitFocusMode()
        XCTAssertFalse(state.isFocusMode)
        XCTAssertEqual(state.activeSpaceID, before)
        XCTAssertFalse(state.spaces.contains { $0.id == focus.id })
        XCTAssertFalse(state.tabs.contains { $0.spaceID == focus.id })
    }

    func testToggleEntersThenLeaves() {
        let state = makeState()
        state.toggleFocusMode()
        XCTAssertTrue(state.isFocusMode)
        state.toggleFocusMode()
        XCTAssertFalse(state.isFocusMode)
    }

    /// Deleting the Focus space from the sidebar must go through the exit path,
    /// so the erase still happens.
    func testRemovingTheFocusSpaceLeavesFocusProperly() {
        let state = makeState()
        let focus = state.enterFocusMode()!
        state.removeSpace(focus.id)
        XCTAssertFalse(state.isFocusMode)
        XCTAssertFalse(state.spaces.contains { $0.id == focus.id })
    }

    // MARK: Nothing is written down

    func testHistoryIsNotRecordedInFocus() {
        let state = makeState()
        let focus = state.enterFocusMode()!
        state.recordVisit(url: url(1), title: "Private", spaceID: focus.id)
        XCTAssertTrue(state.history.entries.isEmpty, "Focus must not write history")
    }

    func testHistoryIsStillRecordedOutsideFocus() {
        let state = makeState()
        let normal = state.activeSpaceID
        state.recordVisit(url: url(1), title: "Public", spaceID: normal)
        XCTAssertEqual(state.history.entries.count, 1)

        // And a normal space keeps recording even while Focus exists.
        let focus = state.enterFocusMode()!
        state.recordVisit(url: url(2), title: "Private", spaceID: focus.id)
        state.recordVisit(url: url(3), title: "Still public", spaceID: normal)
        XCTAssertEqual(state.history.entries.count, 2)
        XCTAssertFalse(state.history.entries.contains { $0.url == url(2) })
    }

    func testSnapshotExcludesTheFocusSpaceAndItsTabs() {
        let state = makeState()
        let focus = state.enterFocusMode()!
        state.newTab(url: url(1))

        let snapshot = state.snapshot()
        XCTAssertFalse(snapshot.spaces.contains { $0.id == focus.id })
        XCTAssertFalse(snapshot.tabs.contains { $0.spaceID == focus.id })
        XCTAssertNotEqual(snapshot.activeSpaceID, focus.id, "never restore into Focus")
        XCTAssertNil(snapshot.activeTabIDBySpace[focus.id.uuidString])
    }

    func testAFocusSessionIsNotRestoredOnRelaunch() {
        let state = makeState()
        state.enterFocusMode()
        state.newTab(url: url(1))
        state.saveNow()

        let restored = makeState(restore: true)
        XCTAssertFalse(restored.isFocusMode)
        XCTAssertFalse(restored.tabs.contains { $0.url == url(1) })
        XCTAssertFalse(restored.spaces.contains { $0.name == "Focus" })
    }

    // MARK: Erase

    func testEraseClearsEveryFocusTabAndOpensAFreshOne() {
        let state = makeState()
        let focus = state.enterFocusMode()!
        state.newTab(url: url(1))
        state.newTab(url: url(2))
        let before = Set(state.tabs.filter { $0.spaceID == focus.id }.map(\.id))
        XCTAssertGreaterThan(before.count, 1)

        state.eraseFocus()

        let after = state.tabs.filter { $0.spaceID == focus.id }
        XCTAssertEqual(after.count, 1, "erase leaves exactly one fresh tab")
        XCTAssertTrue(after[0].isNewTabPage)
        XCTAssertTrue(before.isDisjoint(with: Set(after.map(\.id))), "no tab survives")
        XCTAssertTrue(state.isFocusMode, "erase does not leave the mode")
    }

    /// A new data store identifier is what actually makes the next session new.
    func testEraseRotatesTheDataStoreIdentifier() {
        let state = makeState()
        let focus = state.enterFocusMode()!
        let originalStore = state.spaces.first { $0.id == focus.id }?.dataStoreID
        XCTAssertNotNil(originalStore)

        state.eraseFocus()
        let rotated = state.spaces.first { $0.id == focus.id }?.dataStoreID
        XCTAssertNotNil(rotated)
        XCTAssertNotEqual(originalStore, rotated)
    }

    func testEraseAnnouncesItself() {
        let state = makeState()
        state.enterFocusMode()
        XCTAssertNil(state.focusToast)
        state.eraseFocus()
        XCTAssertEqual(state.focusToast, "Your browsing history has been erased")
    }

    func testLeavingFocusAlsoErasesAndAnnounces() {
        let state = makeState()
        state.enterFocusMode()
        state.newTab(url: url(1))
        state.exitFocusMode()
        XCTAssertEqual(state.focusToast, "Your browsing history has been erased")
        XCTAssertFalse(state.tabs.contains { $0.url == url(1) })
    }

    func testEraseOutsideFocusDoesNothing() {
        let state = makeState()
        let before = state.tabs.map(\.id)
        state.eraseFocus()
        XCTAssertEqual(state.tabs.map(\.id), before)
        XCTAssertNil(state.focusToast)
    }

    /// Essentials belong to no space, so an erase must leave them alone.
    func testEraseDoesNotTouchEssentialsOrOtherSpaces() {
        let state = makeState()
        let essentials = state.essentials.map(\.id)
        let normalTabs = state.tabs.filter { !$0.kind.isGlobal }.map(\.id)

        state.enterFocusMode()
        state.newTab(url: url(1))
        state.eraseFocus()

        XCTAssertEqual(state.essentials.map(\.id), essentials)
        for id in normalTabs {
            XCTAssertTrue(state.tabs.contains { $0.id == id }, "non-Focus tab was erased")
        }
    }

    // MARK: Theme

    func testFocusSpaceHasItsOwnDistinctAccent() {
        let state = makeState()
        let ordinary = state.spaces[0].accent(isDark: true)
        let focus = state.enterFocusMode()!
        XCTAssertNotEqual(focus.accent(isDark: true), ordinary)
        XCTAssertEqual(focus.name, "Focus")
        // Purple: hue in the violet band.
        let hue = focus.theme.primaryDotColor?.hsl.hue ?? 0
        XCTAssertGreaterThan(hue, 250)
        XCTAssertLessThan(hue, 310)
    }
}

/// The shipped blocklist, checked without going near WebKit.
final class ContentBlocklistTests: XCTestCase {

    private func rules() throws -> [[String: Any]] {
        let json = try ContentBlocker.blocklistJSON()
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(parsed as? [[String: Any]])
    }

    func testBlocklistIsPresentAndParses() throws {
        let rules = try rules()
        XCTAssertGreaterThan(rules.count, 150, "a starter list should still be broad")
    }

    /// Every rule must have the two keys WebKit requires, or compilation fails
    /// wholesale and the mode silently blocks nothing.
    func testEveryRuleIsWellFormed() throws {
        for (index, rule) in try rules().enumerated() {
            let trigger = rule["trigger"] as? [String: Any]
            let action = rule["action"] as? [String: Any]
            XCTAssertNotNil(trigger, "rule \(index) has no trigger")
            XCTAssertNotNil(action, "rule \(index) has no action")
            XCTAssertNotNil(trigger?["url-filter"] as? String, "rule \(index) has no url-filter")
            let type = action?["type"] as? String
            XCTAssertTrue(
                ["block", "block-cookies", "css-display-none", "ignore-previous-rules"]
                    .contains(type ?? ""),
                "rule \(index) has an unknown action type \(type ?? "nil")")
        }
    }

    func testWellKnownTrackersAreCovered() throws {
        let json = try ContentBlocker.blocklistJSON()
        for domain in [
            "doubleclick.net", "google-analytics.com", "googletagmanager.com",
            "scorecardresearch.com", "adnxs.com", "criteo.com", "hotjar.com",
            "branch.io", "taboola.com", "demdex.net",
        ] {
            XCTAssertTrue(json.contains(domain), "blocklist is missing \(domain)")
        }
    }

    /// Third-party cookies are blocked by a rule, not a setting — make sure it
    /// survived, and that it is scoped so first-party logins still work.
    func testThirdPartyCookiesAreBlocked() throws {
        let cookieRules = try rules().filter {
            ($0["action"] as? [String: Any])?["type"] as? String == "block-cookies"
        }
        XCTAssertEqual(cookieRules.count, 1)
        let loadType = (cookieRules[0]["trigger"] as? [String: Any])?["load-type"] as? [String]
        XCTAssertEqual(loadType, ["third-party"])
    }

    func testBlocklistCompiles() async throws {
        // WKContentRuleListStore is unavailable in some CI sandboxes; skip
        // rather than fail, since the JSON validity above is the part we own.
        // `default()` is main-actor isolated, and an `async` test method is not
        // — so the hop is explicit rather than implied.
        guard let store = await MainActor.run(body: { WKContentRuleListStore.default() }) else {
            throw XCTSkip("no content rule list store available")
        }
        let json = try ContentBlocker.blocklistJSON()
        // A fixed identifier so repeated runs reuse WebKit's compiled cache
        // instead of accumulating one entry per run.
        let list = try await store.compileContentRuleList(
            forIdentifier: "zen.focus.blocklist.test", encodedContentRuleList: json)
        XCTAssertNotNil(list, "the shipped blocklist must compile")
    }
}
