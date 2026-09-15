//  URLDetectorTests.swift
//  Whether a typed string is a destination or a query is the single decision
//  the omnibox makes on every commit, and the one users notice when it is wrong.

import XCTest

@testable import Zen

final class URLDetectorTests: XCTestCase {

    private let engine = SearchEngine.duckduckgo

    private func assertNavigates(
        _ input: String, to expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch URLDetector.intent(for: input, engine: engine) {
        case .navigate(let url):
            XCTAssertEqual(url.absoluteString, expected, file: file, line: line)
        case .search(let query):
            XCTFail("expected navigation, searched for \(query)", file: file, line: line)
        }
    }

    private func assertSearches(
        _ input: String, for expected: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch URLDetector.intent(for: input, engine: engine) {
        case .navigate(let url):
            XCTFail("expected search, navigated to \(url)", file: file, line: line)
        case .search(let query):
            if let expected {
                XCTAssertEqual(query, expected, file: file, line: line)
            }
        }
    }

    // MARK: Destinations

    func testExplicitSchemesNavigate() {
        assertNavigates("https://example.com", to: "https://example.com")
        assertNavigates("http://example.com/path?q=1", to: "http://example.com/path?q=1")
    }

    func testBareHostnameWithKnownTLDNavigates() {
        assertNavigates("example.com", to: "https://example.com")
        assertNavigates("zen-browser.app", to: "https://zen-browser.app")
        assertNavigates("news.ycombinator.com/newest", to: "https://news.ycombinator.com/newest")
    }

    func testLocalhostNavigates() {
        assertNavigates("localhost", to: "http://localhost")
        assertNavigates("localhost:8080", to: "http://localhost:8080")
        assertNavigates("localhost:3000/admin", to: "http://localhost:3000/admin")
    }

    func testIPv4Navigates() {
        assertNavigates("10.0.0.42", to: "http://10.0.0.42")
        assertNavigates("127.0.0.1:8200/mcp", to: "http://127.0.0.1:8200/mcp")
    }

    func testHomelabTLDsNavigate() {
        assertNavigates("refs.lan", to: "https://refs.lan")
    }

    func testAboutSchemeNavigates() {
        assertNavigates("about:blank", to: "about:blank")
    }

    // MARK: Queries

    func testWhitespaceAlwaysMeansSearch() {
        assertSearches("example.com and friends")
        assertSearches("how to build a browser")
        // Even a valid URL with a space in it is a query, not a destination.
        assertSearches("https://example.com now")
    }

    func testSingleWordIsSearch() {
        assertSearches("swift", for: "swift")
        assertSearches("zen", for: "zen")
    }

    func testUnknownTLDIsSearch() {
        // Otherwise "version 2.0rc" style input navigates into nowhere.
        assertSearches("file.qqq")
        assertSearches("2.0rc")
    }

    func testDangerousSchemesAreSearched() {
        // Never hand javascript: to the web view from the omnibox.
        assertSearches("javascript:alert(1)")
        assertSearches("mailto:andrew.haynes@me.com")
        assertSearches("tel:5551234")
    }

    func testEmptyInputIsAnEmptySearch() {
        assertSearches("", for: "")
        assertSearches("   ", for: "")
    }

    func testInputIsTrimmed() {
        assertNavigates("  example.com  ", to: "https://example.com")
    }

    // MARK: Resolution

    func testResolveProducesSearchURLForQueries() {
        let url = URLDetector.resolve("swift ui", engine: .duckduckgo)
        XCTAssertEqual(url.host, "duckduckgo.com")
        XCTAssertTrue(url.absoluteString.contains("q=swift%20ui"))
    }

    func testResolveProducesNavigationForURLs() {
        XCTAssertEqual(
            URLDetector.resolve("example.com", engine: .duckduckgo).absoluteString,
            "https://example.com")
    }

    /// A literal `+` must survive to the server as `%2B`, or "c++" searches for
    /// "c  ".
    func testPlusIsEncodedInSearchQueries() {
        let url = SearchEngine.google.searchURL(for: "c++ lambda")
        XCTAssertTrue(url.absoluteString.contains("%2B%2B"), url.absoluteString)
    }

    func testEveryEngineProducesAQueryURL() {
        for engine in SearchEngine.allCases {
            let url = engine.searchURL(for: "zen browser")
            XCTAssertEqual(url.scheme, "https", engine.displayName)
            XCTAssertEqual(url.host, engine.host, engine.displayName)
            XCTAssertTrue(
                url.query?.contains("q=") == true, "\(engine.displayName): \(url)")
        }
    }

    func testEveryEngineHasASuggestionsEndpoint() {
        for engine in SearchEngine.allCases {
            XCTAssertNotNil(engine.suggestionsURL(for: "zen"), engine.displayName)
        }
        XCTAssertNil(SearchEngine.duckduckgo.suggestionsURL(for: ""))
    }

    // MARK: Display

    func testPrettyHostStripsWWW() {
        XCTAssertEqual(
            URLDetector.prettyHost(URL(string: "https://www.example.com/x")), "example.com")
        XCTAssertEqual(
            URLDetector.prettyHost(URL(string: "https://news.ycombinator.com")),
            "news.ycombinator.com")
        XCTAssertEqual(URLDetector.prettyHost(nil), "")
    }
}
