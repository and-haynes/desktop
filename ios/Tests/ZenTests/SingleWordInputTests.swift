//  SingleWordInputTests.swift
//  `meitner` is the one genuinely ambiguous thing you can type into a URL bar:
//  it is a machine on a home network and it is a search term, and the string
//  itself does not say which. The rule is that it searches, that the other
//  reading is always offered explicitly, and that having actually been to the
//  host flips the default.

import XCTest

@testable import Zen

@MainActor
final class SingleWordInputTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenSingleWord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func history() -> HistoryStore {
        HistoryStore(file: JSONFileStore<[HistoryEntry]>(name: "history.json", directory: directory))
    }

    // MARK: Recognising a bare name

    func testABareWordIsASingleLabelName() {
        XCTAssertEqual(URLDetector.singleLabelName("meitner"), "meitner")
        XCTAssertEqual(URLDetector.singleLabelName("  meitner  "), "meitner")
        XCTAssertEqual(URLDetector.singleLabelName("pi-b"), "pi-b")
    }

    /// Anything that already resolves on its own is not ambiguous and must not
    /// get a second row offering what the first row already does.
    func testThingsThatAreAlreadyUnambiguousAreNotSingleLabelNames() {
        XCTAssertNil(URLDetector.singleLabelName("example.com"))
        XCTAssertNil(URLDetector.singleLabelName("meitner:8006"))
        XCTAssertNil(URLDetector.singleLabelName("meitner/status"))
        XCTAssertNil(URLDetector.singleLabelName("http://meitner"))
        XCTAssertNil(URLDetector.singleLabelName("swift ui"))
        XCTAssertNil(URLDetector.singleLabelName("localhost"))
        XCTAssertNil(URLDetector.singleLabelName(""))
        XCTAssertNil(URLDetector.singleLabelName("-meitner"))
        XCTAssertNil(URLDetector.singleLabelName("meitner-"))
        XCTAssertNil(URLDetector.singleLabelName("42"), "a number is not a host")
    }

    func testABareNameResolvesOverPlainHTTP() {
        XCTAssertEqual(
            URLDetector.singleLabelURL("meitner")?.absoluteString, "http://meitner")
    }

    // MARK: The default: search

    func testABareWordStillSearches() {
        switch URLDetector.intent(for: "meitner", engine: .duckduckgo) {
        case .search(let term): XCTAssertEqual(term, "meitner")
        case .navigate(let url): XCTFail("a word we have never seen navigated to \(url)")
        }
    }

    // MARK: …unless we have been there

    func testAKnownHostNavigates() {
        switch URLDetector.intent(
            for: "meitner", engine: .duckduckgo, knownHosts: ["meitner"])
        {
        case .navigate(let url): XCTAssertEqual(url.absoluteString, "http://meitner")
        case .search: XCTFail("a host we have visited should navigate")
        }
    }

    func testMatchingAKnownHostIsCaseInsensitive() {
        switch URLDetector.intent(
            for: "Meitner", engine: .duckduckgo, knownHosts: ["meitner"])
        {
        case .navigate(let url): XCTAssertEqual(url.absoluteString, "http://Meitner")
        case .search: XCTFail("host matching should ignore case")
        }
    }

    func testAnUnrelatedKnownHostDoesNotCaptureOtherWords() {
        switch URLDetector.intent(
            for: "pottery", engine: .duckduckgo, knownHosts: ["meitner"])
        {
        case .search(let term): XCTAssertEqual(term, "pottery")
        case .navigate(let url): XCTFail("unexpected navigation to \(url)")
        }
    }

    func testResolveHonoursKnownHosts() {
        XCTAssertEqual(
            URLDetector.resolve("meitner", engine: .duckduckgo, knownHosts: ["meitner"])
                .absoluteString, "http://meitner")
        XCTAssertTrue(
            URLDetector.resolve("meitner", engine: .duckduckgo).absoluteString
                .contains("duckduckgo.com"))
    }

    // MARK: History supplies the known hosts

    func testHistoryReportsItsSingleLabelHosts() {
        let store = history()
        store.record(url: URL(string: "http://meitner:8006/")!, title: "Proxmox")
        store.record(url: URL(string: "https://example.com/")!, title: "Example")
        store.record(url: URL(string: "http://localhost:3000/")!, title: "Dev")
        XCTAssertEqual(store.singleLabelHosts, ["meitner"])
    }

    // MARK: The second row

    func testABareWordOffersGoToAsTheSecondRow() {
        let state = BrowserState(
            session: SessionStore(
                file: JSONFileStore<SessionSnapshot>(name: "s.json", directory: directory)),
            history: history(), restore: false)
        let engine = SuggestionEngine()
        engine.update(query: "meitner", state: state)

        XCTAssertEqual(engine.suggestions.first?.kind, .topHit)
        XCTAssertEqual(engine.suggestions.first?.subtitle, "Search with DuckDuckGo")

        let second = engine.suggestions.dropFirst().first
        XCTAssertEqual(second?.kind, .goToHost(URL(string: "http://meitner")!))
        XCTAssertEqual(second?.title, "Go to http://meitner")
    }

    /// Once the host is known the top hit navigates, and it is *searching* that
    /// becomes the explicit second option.
    func testAKnownHostFlipsTheRows() {
        let store = history()
        store.record(url: URL(string: "http://meitner/")!, title: "Meitner")
        let state = BrowserState(
            session: SessionStore(
                file: JSONFileStore<SessionSnapshot>(name: "s.json", directory: directory)),
            history: store, restore: false)
        let engine = SuggestionEngine()
        engine.update(query: "meitner", state: state)

        XCTAssertEqual(engine.suggestions.first?.subtitle, "Open link")
        XCTAssertEqual(engine.suggestions.first?.title, "http://meitner")
        let second = engine.suggestions.dropFirst().first
        XCTAssertEqual(second?.kind, .searchTerm)
        XCTAssertEqual(second?.title, "meitner")
    }

    /// A query that is already a URL must not grow a redundant "Go to" row.
    func testAnUnambiguousQueryGetsNoExtraRow() {
        let state = BrowserState(
            session: SessionStore(
                file: JSONFileStore<SessionSnapshot>(name: "s.json", directory: directory)),
            history: history(), restore: false)
        let engine = SuggestionEngine()
        engine.update(query: "example.com", state: state)
        XCTAssertFalse(
            engine.suggestions.contains { if case .goToHost = $0.kind { return true } else { return false } })
    }
}
