//  ExtensionTabMappingTests.swift
//  `tabs.*`, answered out of `BrowserState`.
//
//  WebKit does not know what a tab is: everything an extension can learn or do
//  about tabs goes through `WKWebExtensionTab`, which is the adapter tested
//  here. The interesting cases are the ones where Zen's model has more in it
//  than the API does — three tiers of tab, Glance cards, Focus mode — because
//  those are the places a mapping can quietly be wrong and an extension sees a
//  tab list that does not match the sidebar.
//
//  Gated on iOS 18.4: below it there is no `WKWebExtensionContext` to pass, so
//  there is nothing to test rather than something that fails.

import WebKit
import XCTest

@testable import Zen

@available(iOS 18.4, *)
@MainActor
final class ExtensionTabMappingTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = ExtensionFixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        ExtensionFixtures.cleanUp(directory)
    }

    private func makeState() -> BrowserState {
        BrowserState(
            session: SessionStore(
                file: JSONFileStore<SessionSnapshot>(name: "session.json", directory: directory),
                debounceInterval: 60),
            history: HistoryStore(
                file: JSONFileStore<[HistoryEntry]>(name: "history.json", directory: directory)),
            bookmarks: BookmarkStore(
                file: JSONFileStore<[Bookmark]>(name: "bookmarks.json", directory: directory)),
            restore: false)
    }

    /// A real context over the real fixture: the proxy takes one on every call,
    /// and a stub would be asserting against a stub.
    private func makeContext() async throws -> WKWebExtensionContext {
        let url = try ExtensionFixtures.directory("zen-badge")
        let webExtension = try await WKWebExtension(resourceBaseURL: url)
        return WKWebExtensionContext(for: webExtension)
    }

    private func proxy(_ id: UUID, _ state: BrowserState) -> ExtensionTabProxy {
        ExtensionTabProxy(tabID: id, state: state, pool: nil, resolver: nil)
    }

    // MARK: What a tab reports

    func testATabReportsItsURLAndTitle() async throws {
        let context = try await makeContext()
        let state = makeState()
        let tab = try XCTUnwrap(state.newTab(url: URL(string: "https://example.com/a")!))
        state.updateTab(tab.id) { $0.title = "Example" }

        let proxy = proxy(tab.id, state)
        XCTAssertEqual(proxy.url(for: context)?.absoluteString, "https://example.com/a")
        XCTAssertEqual(proxy.title(for: context), "Example")
    }

    func testTheStartPageIsReportedAsAboutBlank() async throws {
        let context = try await makeContext()
        let state = makeState()
        let tab = try XCTUnwrap(state.newTab())
        XCTAssertTrue(state.tab(id: tab.id)?.isNewTabPage == true)
        XCTAssertEqual(
            proxy(tab.id, state).url(for: context)?.absoluteString, "about:blank",
            "`zen://newtab` is our own sentinel; an extension has no idea what it is")
    }

    func testEssentialAndPinnedTabsReportAsPinned() async throws {
        let context = try await makeContext()
        let state = makeState()
        let tab = try XCTUnwrap(state.newTab(url: URL(string: "https://example.com")!))
        let proxy = proxy(tab.id, state)
        XCTAssertFalse(proxy.isPinned(for: context))

        state.setKind(.pinned, for: tab.id)
        XCTAssertTrue(proxy.isPinned(for: context))
        state.setKind(.essential, for: tab.id)
        XCTAssertTrue(
            proxy.isPinned(for: context),
            "an essential survives a close, which is what pinned means to an extension")
    }

    func testSelectionMapsToTheActiveTab() async throws {
        let context = try await makeContext()
        let state = makeState()
        let first = try XCTUnwrap(state.newTab(url: URL(string: "https://one.example")!))
        let second = try XCTUnwrap(state.newTab(url: URL(string: "https://two.example")!))

        XCTAssertTrue(proxy(second.id, state).isSelected(for: context))
        XCTAssertFalse(proxy(first.id, state).isSelected(for: context))

        let expectation = expectation(description: "activated")
        proxy(first.id, state).activate(for: context) { error in
            XCTAssertNil(error)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(state.activeTabID, first.id)
    }

    // MARK: What a tab can be told to do

    func testLoadURLGoesThroughTheModel() async throws {
        let context = try await makeContext()
        let state = makeState()
        let tab = try XCTUnwrap(state.newTab(url: URL(string: "https://one.example")!))
        state.updateTab(tab.id) { $0.title = "One" }

        let expectation = expectation(description: "loaded")
        proxy(tab.id, state).loadURL(URL(string: "https://two.example/x")!, for: context) { _ in
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(state.tab(id: tab.id)?.url.absoluteString, "https://two.example/x")
        XCTAssertEqual(
            state.tab(id: tab.id)?.title, "",
            "the title belongs to the previous page and has to go with it")
    }

    func testClosingATabClosesIt() async throws {
        let context = try await makeContext()
        let state = makeState()
        let keep = try XCTUnwrap(state.newTab(url: URL(string: "https://keep.example")!))
        let doomed = try XCTUnwrap(state.newTab(url: URL(string: "https://doomed.example")!))

        let expectation = expectation(description: "closed")
        proxy(doomed.id, state).close(for: context) { _ in expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertNil(state.tab(id: doomed.id))
        XCTAssertNotNil(state.tab(id: keep.id))
    }

    func testPinningThroughTheAPIPromotesTheTab() async throws {
        let context = try await makeContext()
        let state = makeState()
        let tab = try XCTUnwrap(state.newTab(url: URL(string: "https://example.com")!))

        let expectation = expectation(description: "pinned")
        proxy(tab.id, state).setPinned(true, for: context) { _ in expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(state.tab(id: tab.id)?.kind, .pinned)
        XCTAssertNotNil(
            state.tab(id: tab.id)?.pinnedURL, "pinning records the URL it was pinned at")
    }

    /// Zen asks at install time; a click in the page must not widen anything.
    func testAUserGestureDoesNotGrantPermissions() async throws {
        let context = try await makeContext()
        let state = makeState()
        let tab = try XCTUnwrap(state.newTab())
        XCTAssertFalse(proxy(tab.id, state).shouldGrantPermissionsOnUserGesture(for: context))
    }

    // MARK: Which tabs an extension may see at all

    func testFocusTabsAreInvisibleToExtensions() {
        let state = makeState()
        _ = state.newTab(url: URL(string: "https://normal.example")!)
        state.enterFocusMode()
        let secret = state.newTab(url: URL(string: "https://private.example")!)
        XCTAssertNotNil(secret)

        let visible = ExtensionEngine.visibleTabs(in: state)
        XCTAssertFalse(
            visible.contains { $0.id == secret?.id },
            "Focus promises nothing is recorded; an extension enumerating it would be a record")
        XCTAssertTrue(visible.contains { $0.url.absoluteString == "https://normal.example" })
    }

    func testAnUnpromotedGlanceIsNotATab() {
        let state = makeState()
        _ = state.newTab(url: URL(string: "https://page.example")!)
        state.openGlance(url: URL(string: "https://peek.example")!)
        let glanceID = try? XCTUnwrap(state.glanceTabID)

        XCTAssertFalse(
            ExtensionEngine.visibleTabs(in: state).contains { $0.id == glanceID },
            "a Glance card is not in the sidebar, so it is not in `tabs.query` either")

        state.expandGlance()
        XCTAssertTrue(ExtensionEngine.visibleTabs(in: state).contains { $0.id == glanceID })
    }

    // MARK: Match patterns

    func testMatchPatternsParseTheWayTheStoreWritesThem() throws {
        let all = try XCTUnwrap(ExtensionEngine.matchPattern("<all_urls>"))
        XCTAssertTrue(all.matchesAllURLs)
        XCTAssertTrue(all.matches(URL(string: "https://anything.example/x")!))

        let single = try XCTUnwrap(
            ExtensionEngine.matchPattern(InstalledExtension.pattern(forHost: "example.com")))
        XCTAssertTrue(single.matches(URL(string: "https://example.com/page")!))
        XCTAssertFalse(single.matches(URL(string: "https://other.example/page")!))

        XCTAssertNil(ExtensionEngine.matchPattern("not a pattern at all"))
    }

    // MARK: The window

    func testTheWindowListsTheSpacesTabsInSidebarOrder() async throws {
        let context = try await makeContext()
        let state = makeState()
        let window = ExtensionWindowProxy(state: state)
        let normal = try XCTUnwrap(state.newTab(url: URL(string: "https://normal.example")!))
        let pinned = try XCTUnwrap(state.newTab(url: URL(string: "https://pinned.example")!))
        state.setKind(.pinned, for: pinned.id)

        window.tabProxies = [proxy(pinned.id, state), proxy(normal.id, state)]
        XCTAssertEqual(window.tabs(for: context).count, 2)
        XCTAssertEqual(window.orderedTabIDs, [pinned.id, normal.id])
        XCTAssertEqual(window.windowType(for: context), .normal)
        XCTAssertFalse(
            window.isPrivate(for: context),
            "Focus never gets a controller, so no window an extension sees is private")
    }

    func testAWindowCannotBeClosedOnIOS() async throws {
        let context = try await makeContext()
        let window = ExtensionWindowProxy(state: makeState())
        let expectation = expectation(description: "refused")
        window.close(for: context) { error in
            XCTAssertNotNil(error, "an app cannot close itself, and saying so beats a no-op")
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1)
    }
}
