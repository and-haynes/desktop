//  SessionStoreTests.swift
//  Session restore is the feature people notice only when it fails, so the
//  round-trip and the "refuse to restore something broken" rules are tested.

import XCTest

@testable import Zen

final class SessionStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> SessionStore {
        SessionStore(
            file: JSONFileStore<SessionSnapshot>(name: "session.json", directory: directory),
            debounceInterval: 0.01)
    }

    private func makeSnapshot() -> (SessionSnapshot, Space, Tab) {
        let space = Space(
            name: "Work", icon: "briefcase.fill", isSymbol: true,
            theme: ZenGradientGenerator.theme(
                seed: ZenColor(hueDegrees: 200, saturation: 95, lightness: 55)))
        var essential = Tab(
            url: URL(string: "https://zen-browser.app")!, title: "Zen", kind: .essential,
            pinnedURL: URL(string: "https://zen-browser.app")!)
        essential.faviconData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var normal = Tab(
            url: URL(string: "https://example.com")!, title: "Example", kind: .normal,
            spaceID: space.id)
        normal.scrollY = 812.5
        let snapshot = SessionSnapshot(
            spaces: [space], tabs: [essential, normal], activeSpaceID: space.id,
            activeTabIDBySpace: [space.id: normal.id], settings: {
                var s = ZenSettings()
                s.searchEngine = .ecosia
                s.compactModeEnabled = true
                s.preferDesktopSite = true
                return s
            }())
        return (snapshot, space, normal)
    }

    // MARK: Round trip

    func testRoundTripPreservesEverything() throws {
        let store = makeStore()
        let (snapshot, space, normal) = makeSnapshot()

        XCTAssertTrue(store.saveNow(snapshot))
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.version, SessionSnapshot.currentVersion)
        XCTAssertEqual(loaded.spaces.count, 1)
        XCTAssertEqual(loaded.spaces[0].id, space.id)
        XCTAssertEqual(loaded.spaces[0].name, "Work")
        XCTAssertEqual(loaded.spaces[0].icon, "briefcase.fill")
        XCTAssertTrue(loaded.spaces[0].isSymbol)
        XCTAssertEqual(loaded.spaces[0].theme.dots.count, snapshot.spaces[0].theme.dots.count)
        XCTAssertEqual(loaded.spaces[0].theme.primaryDotColor, snapshot.spaces[0].theme.primaryDotColor)

        XCTAssertEqual(loaded.tabs.count, 2)
        XCTAssertEqual(loaded.tabs[0].kind, .essential)
        XCTAssertEqual(loaded.tabs[0].faviconData, Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(loaded.tabs[0].pinnedURL?.absoluteString, "https://zen-browser.app")
        XCTAssertEqual(loaded.tabs[1].scrollY, 812.5, accuracy: 0.001)
        XCTAssertEqual(loaded.tabs[1].spaceID, space.id)

        XCTAssertEqual(loaded.activeSpaceID, space.id)
        XCTAssertEqual(loaded.activeTabIDs[space.id], normal.id)
        XCTAssertEqual(loaded.settings.searchEngine, .ecosia)
        XCTAssertTrue(loaded.settings.compactModeEnabled)
        XCTAssertTrue(loaded.settings.preferDesktopSite)
    }

    func testLoadOfMissingFileReturnsNil() {
        XCTAssertNil(makeStore().load())
    }

    func testCorruptFileDoesNotCrashOrRestore() throws {
        let url = directory.appendingPathComponent("session.json")
        try Data("{ this is not json".utf8).write(to: url)
        XCTAssertNil(makeStore().load())
    }

    /// A snapshot written by a future build must be refused rather than
    /// partially decoded into a mangled browser.
    func testFutureVersionIsRefused() throws {
        var (snapshot, _, _) = makeSnapshot()
        snapshot.version = SessionSnapshot.currentVersion + 1
        let file = JSONFileStore<SessionSnapshot>(name: "session.json", directory: directory)
        file.save(snapshot)
        XCTAssertNil(makeStore().load())
    }

    // MARK: Atomicity

    func testSaveIsAtomicAndLeavesNoTempFiles() throws {
        let store = makeStore()
        let (snapshot, _, _) = makeSnapshot()
        for _ in 0..<5 { XCTAssertTrue(store.saveNow(snapshot)) }

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".tmp") }, [])
        XCTAssertEqual(contents, ["session.json"])
    }

    func testOverwritingAnExistingFileWorks() throws {
        let store = makeStore()
        var (snapshot, space, _) = makeSnapshot()
        store.saveNow(snapshot)

        snapshot.spaces[0].name = "Renamed"
        store.saveNow(snapshot)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.spaces[0].name, "Renamed")
        XCTAssertEqual(loaded.spaces[0].id, space.id)
    }

    func testFlushWritesCoalescedState() throws {
        let store = makeStore()
        let (snapshot, _, _) = makeSnapshot()
        store.save(snapshot)
        // Nothing has hit disk yet; flush must not lose it.
        store.flush()
        XCTAssertNotNil(store.load())
    }

    func testFlushWithNothingPendingIsHarmless() {
        makeStore().flush()
    }

    // MARK: Sanitising

    /// A tab whose space no longer exists would render as a tab you cannot
    /// reach; drop it instead.
    func testOrphanedTabsAreDropped() throws {
        let store = makeStore()
        var (snapshot, space, _) = makeSnapshot()
        let ghost = Tab(
            url: URL(string: "https://ghost.example")!, kind: .normal, spaceID: UUID())
        snapshot.tabs.append(ghost)
        store.saveNow(snapshot)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertFalse(loaded.tabs.contains { $0.id == ghost.id })
        // Essentials belong to no space and must survive.
        XCTAssertTrue(loaded.tabs.contains { $0.kind == .essential })
        XCTAssertEqual(loaded.activeSpaceID, space.id)
    }

    func testActiveTabPointerToADeadTabIsDropped() throws {
        let store = makeStore()
        var (snapshot, space, _) = makeSnapshot()
        snapshot.activeTabIDBySpace = [space.id.uuidString: UUID()]
        store.saveNow(snapshot)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertNil(loaded.activeTabIDs[space.id])
    }

    func testDeletedActiveSpaceFallsBackToTheFirstSpace() throws {
        let store = makeStore()
        var (snapshot, space, _) = makeSnapshot()
        snapshot.activeSpaceID = UUID()
        store.saveNow(snapshot)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.activeSpaceID, space.id)
    }

    /// Tabs come back unloaded — nothing is restored into a live web view.
    func testRestoredTabsAreUnloaded() throws {
        let store = makeStore()
        var (snapshot, _, _) = makeSnapshot()
        snapshot.tabs[0].isLoaded = true
        store.saveNow(snapshot)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertTrue(loaded.tabs.allSatisfy { !$0.isLoaded })
    }

    // MARK: Other stores

    func testHistoryAndBookmarkFilesRoundTrip() throws {
        let historyFile = JSONFileStore<[HistoryEntry]>(name: "history.json", directory: directory)
        let entries = [
            HistoryEntry(
                url: URL(string: "https://example.com")!, title: "Example",
                lastVisited: Date(timeIntervalSince1970: 1_700_000_000), visitCount: 7)
        ]
        historyFile.save(entries)
        let loaded = try XCTUnwrap(historyFile.load())
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].visitCount, 7)
        XCTAssertEqual(loaded[0].title, "Example")
    }
}
