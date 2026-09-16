//  ExtensionRuntimeTests.swift
//  That WebKit actually accepts what we hand it.
//
//  Everything else in the suite tests our own code against our own code: the
//  manifest parser against a fixture, the store against a temp directory. This
//  is the one that puts a real `WKWebExtensionController` on the other side,
//  because the interesting failures all live there — a manifest WebKit dislikes
//  for a reason ours does not, a context whose permissions were set after the
//  load instead of before, a controller created without a website data store.
//
//  It is also the regression test for the bug that made the first version of
//  this feature look finished and do nothing: the browsing web view is built
//  during the first layout pass, which is *earlier* than any `onAppear`, so a
//  runtime that waited to be handed the browser handed out no controller and
//  the tab could never run an extension again.

import WebKit
import XCTest

@testable import Zen

@available(iOS 18.4, *)
@MainActor
final class ExtensionRuntimeTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = ExtensionFixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        ExtensionFixtures.cleanUp(scratch)
    }

    private func makeHost() -> ExtensionHost {
        ExtensionHost(
            store: ExtensionStore(
                file: JSONFileStore<[InstalledExtension]>(
                    url: scratch.appendingPathComponent("extensions.json")),
                root: scratch.appendingPathComponent("Extensions", isDirectory: true)))
    }

    private func makeState() -> BrowserState {
        BrowserState(
            session: SessionStore(
                file: JSONFileStore<SessionSnapshot>(name: "session.json", directory: scratch),
                debounceInterval: 60),
            history: HistoryStore(
                file: JSONFileStore<[HistoryEntry]>(name: "history.json", directory: scratch)),
            bookmarks: BookmarkStore(
                file: JSONFileStore<[Bookmark]>(name: "bookmarks.json", directory: scratch)),
            restore: false)
    }

    /// Install a fixture with everything it asked for, the way the install
    /// sheet's default does.
    @discardableResult
    private func install(_ name: String, into host: ExtensionHost) throws -> InstalledExtension {
        let prepared = try host.store.prepare(
            directory: try ExtensionFixtures.directory(name), source: .bundled(name: name))
        return try host.store.commit(
            prepared,
            grantedPermissions: Set(prepared.record.requestedPermissions),
            grantedHostPatterns: Set(prepared.record.requestedHostPatterns))
    }

    /// Loading is a `Task`, so give it a moment and then stop waiting.
    private func waitForLoad(_ host: ExtensionHost, _ identifier: String) async {
        for _ in 0..<80 {
            if host.isLoaded(identifier) || host.loadErrors[identifier] != nil { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: Measuring a block

    /// What one pass of the probe page saw.
    private struct BlockingProbe {
        var attempts = 0
        /// The control resource ran, so the page loaded at all. Without this
        /// every other field is meaningless — an unreachable page also fails
        /// to fetch the resource that was supposed to be blocked.
        var pageLoaded = false
        /// The blocked resource's script executed in the page.
        var blockedArrived = true
        /// The server was asked for it, which is the difference between
        /// "blocked" and "requested and then failed".
        var serverWasAsked = true

        var isBlocked: Bool { pageLoaded && !blockedArrived && !serverWasAsked }
    }

    /// Load the probe page and report what the blocker did to it, retrying
    /// with a freshly built web view until it blocks or the deadline passes.
    ///
    /// The retry is not flake-hiding, it is the API: WebKit compiles a
    /// `declarativeNetRequest` ruleset asynchronously once the context is
    /// loaded, `isLoaded` goes true before that finishes, and there is no
    /// public signal for when the compiled list is live —
    /// `WKWebExtensionContext` exposes `loaded` and nothing about its rules. A
    /// single probe behind a fixed sleep therefore measures the machine's load
    /// rather than the browser's behaviour, and did: both blocking tests passed
    /// and failed on the same commit within ten minutes. A fresh view per
    /// attempt because a compiled rule list reaches a page through the
    /// configuration its view was built with, which is the same reason
    /// installing an extension rebuilds the open tabs.
    private func probeBlocking(
        server: LoopbackServer,
        page: URL,
        window: UIWindow,
        attempts: Int = 12,
        makeView: () -> ZenWebView
    ) async -> BlockingProbe {
        var probe = BlockingProbe()
        for attempt in 1...attempts {
            probe = BlockingProbe(attempts: attempt)
            server.resetRequests()
            let view = makeView()
            window.addSubview(view)
            view.load(URLRequest(url: page))
            for _ in 0..<100 {
                if let arrived = try? await view.evaluateJavaScript(
                    "window.zenAllowedArrived === true") as? Bool, arrived
                {
                    probe.pageLoaded = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            // Long enough for a request that was going to arrive to arrive.
            try? await Task.sleep(for: .milliseconds(500))
            probe.blockedArrived =
                (try? await view.evaluateJavaScript("window.zenBlockedArrived === true") as? Bool)
                ?? true
            probe.serverWasAsked = server.wasRequested("/zen-blocked-resource.js")
            if probe.isBlocked { return probe }
            view.removeFromSuperview()
            try? await Task.sleep(for: .milliseconds(250))
        }
        return probe
    }

    // MARK: The load

    func testWebKitLoadsOurFixturePackage() async throws {
        let host = makeHost()
        let state = makeState()
        let record = try install("zen-badge", into: host)
        host.start(state: state, pool: WebViewPool())
        let space = try XCTUnwrap(state.activeSpace)

        XCTAssertNotNil(
            host.controller(for: space, ephemeral: false), "no controller for a normal space")
        await waitForLoad(host, record.id)

        XCTAssertNil(
            host.loadErrors[record.id],
            "WebKit refused the package: \(host.loadErrors[record.id] ?? "")")
        XCTAssertTrue(host.isLoaded(record.id), "the context never reached the controller")
    }

    /// The one that matters: a controller must be available *before* anyone has
    /// told the runtime what the browser is, because that is the real order.
    func testAControllerIsHandedOutBeforeTheBrowserIsAttached() async throws {
        let host = makeHost()
        let record = try install("zen-badge", into: host)
        // Deliberately not started yet — this is a web view being built during
        // the first layout pass.
        let space = Space(name: "Personal", icon: "house.fill", isSymbol: true)
        let controller = host.controller(for: space, ephemeral: false)
        XCTAssertNotNil(
            controller,
            "a configuration built before `start` would never be able to run an extension — "
                + "`webExtensionController` cannot be set after the web view exists")

        // And when the browser does turn up, the same controller gets loaded.
        let state = makeState()
        state.setSpaces([space])
        state.repairSelection()
        host.start(state: state, pool: WebViewPool())
        await waitForLoad(host, record.id)
        XCTAssertTrue(
            host.controller(for: space, ephemeral: false) === controller,
            "attaching must not replace the controller the web view already holds")
        XCTAssertNil(host.loadErrors[record.id], host.loadErrors[record.id] ?? "")
        XCTAssertTrue(host.isLoaded(record.id))
    }

    func testEphemeralBrowsingGetsNoController() throws {
        let host = makeHost()
        let state = makeState()
        host.start(state: state, pool: WebViewPool())
        let space = try XCTUnwrap(state.activeSpace)
        XCTAssertNil(host.controller(for: space, ephemeral: true))
    }

    /// Each space is its own controller, which is the whole storage-isolation
    /// argument — if two spaces shared one, an extension's `storage.local` in
    /// Work would be the one it has in Personal.
    func testEachSpaceGetsItsOwnController() throws {
        let host = makeHost()
        let state = makeState()
        host.start(state: state, pool: WebViewPool())
        let spaces = state.spaces
        XCTAssertGreaterThanOrEqual(spaces.count, 2, "the starter set has Personal and Work")
        let first = host.controller(for: spaces[0], ephemeral: false)
        let second = host.controller(for: spaces[1], ephemeral: false)
        XCTAssertNotNil(first)
        XCTAssertFalse(first === second)
        XCTAssertTrue(
            host.controller(for: spaces[0], ephemeral: false) === first,
            "a space's controller is stable, or every new web view starts a new background page")
    }

    // MARK: Actions

    func testALoadedExtensionPublishesItsAction() async throws {
        let host = makeHost()
        let state = makeState()
        let record = try install("zen-badge", into: host)
        host.start(state: state, pool: WebViewPool())
        _ = host.controller(for: try XCTUnwrap(state.activeSpace), ephemeral: false)
        await waitForLoad(host, record.id)
        host.tabsChanged()

        let action = try XCTUnwrap(
            host.actions.first { $0.id == record.id },
            "a loaded extension with an `action` key must reach the bar")
        XCTAssertEqual(action.name, "Zen Badge")
        XCTAssertTrue(
            action.presentsPopup,
            "the fixture declares `default_popup`, so tapping it must open one")
    }

    func testDisablingAnExtensionUnloadsIt() async throws {
        let host = makeHost()
        let state = makeState()
        let record = try install("zen-badge", into: host)
        host.start(state: state, pool: WebViewPool())
        _ = host.controller(for: try XCTUnwrap(state.activeSpace), ephemeral: false)
        await waitForLoad(host, record.id)
        XCTAssertTrue(host.isLoaded(record.id))

        host.store.setEnabled(false, for: record.id)
        host.installedChanged()
        XCTAssertFalse(host.isLoaded(record.id), "disabling has to unload, not just grey out")
        XCTAssertTrue(host.actions.isEmpty)
    }

    func testTheBlockerLoadsItsRuleset() async throws {
        let host = makeHost()
        let state = makeState()
        let record = try install("zen-blocker", into: host)
        host.start(state: state, pool: WebViewPool())
        _ = host.controller(for: try XCTUnwrap(state.activeSpace), ephemeral: false)
        await waitForLoad(host, record.id)
        XCTAssertNil(
            host.loadErrors[record.id],
            "a declarativeNetRequest ruleset WebKit cannot compile fails the whole load: "
                + (host.loadErrors[record.id] ?? ""))
        XCTAssertTrue(host.isLoaded(record.id))
        XCTAssertTrue(host.runtimeErrors(record.id).isEmpty, "\(host.runtimeErrors(record.id))")
    }

    // MARK: Into an actual page

    /// The end of the chain: a web view built by the pool must carry the
    /// controller, and WebKit must inject the fixture's content script into a
    /// page loaded in it.
    ///
    /// This is the assertion that would have caught the ordering bug above in
    /// two seconds rather than in a three-minute UI run, which is why it is
    /// here and not only in `ScreenshotTests`.
    func testAContentScriptRunsInABrowsingWebView() async throws {
        let host = makeHost()
        let state = makeState()
        let record = try install("zen-badge", into: host)
        let pool = WebViewPool()
        pool.state = state
        pool.extensions = host
        host.start(state: state, pool: pool)
        let space = try XCTUnwrap(state.activeSpace)
        // Ask for the controller and let the context finish loading *before*
        // building a web view. Loading an extension rebuilds the open ones
        // (see `rebuildBrowsingViews`), so a view made mid-load is a view that
        // is about to be thrown away — which is a real behaviour, tested in
        // `testInstallingABlockerAffectsATabThatWasAlreadyOpen`, and not the
        // one being measured here.
        _ = host.controller(for: space, ephemeral: false)
        await waitForLoad(host, record.id)

        let tab = try XCTUnwrap(state.newTab(url: URL(string: "https://fixture.example/page")!))
        let view = pool.webView(for: tab, space: space, desktop: false)
        XCTAssertNotNil(
            view.configuration.webExtensionController,
            "the pool built a web view with no extension controller — nothing loaded into it "
                + "can ever run an extension")

        // In a window and laid out, as the AutoFill fixtures are: WebKit does
        // less for a view that was never put on screen.
        let window = UIWindow(frame: .init(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(view)
        window.isHidden = false
        view.loadHTMLString(
            "<!doctype html><html><body><h1>Fixture</h1></body></html>",
            baseURL: URL(string: "https://fixture.example/page"))

        for _ in 0..<200 {
            let found =
                try? await view.evaluateJavaScript(
                    "!!document.getElementById('zen-extension-badge')") as? Bool
            if found == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail(
            "the content script never ran. loaded=\(host.isLoaded(record.id)) "
                + "error=\(host.loadErrors[record.id] ?? "none") "
                + "runtime=\(host.runtimeErrors(record.id))")
    }

    /// The blocking half, against a server that really is there.
    ///
    /// This is the only way to tell "blocked" from "failed": pointed at a
    /// hostname that does not resolve, every probe reports failure and the
    /// test passes whether or not the extension does anything. So the resource
    /// is served, for real, on loopback — and the assertion is that it does
    /// not arrive *and* that the server was never asked for it.
    func testDeclarativeNetRequestBlocksARequestThatWouldOtherwiseArrive() async throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        server.serve("/zen-blocked-resource.js", javascript: "window.zenBlockedArrived = true;")
        server.serve("/allowed.js", javascript: "window.zenAllowedArrived = true;")
        server.serve("/page.html", html: server.probePage)

        let host = makeHost()
        let state = makeState()
        let record = try install("zen-blocker", into: host)
        let pool = WebViewPool()
        pool.state = state
        pool.extensions = host
        host.start(state: state, pool: pool)
        let space = try XCTUnwrap(state.activeSpace)
        // As above: the controller first, the load next, the web view last.
        _ = host.controller(for: space, ephemeral: false)
        await waitForLoad(host, record.id)
        XCTAssertNil(host.loadErrors[record.id], host.loadErrors[record.id] ?? "")

        let tab = try XCTUnwrap(state.newTab(url: server.url("/page.html")))
        let window = UIWindow(frame: .init(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let probe = await probeBlocking(
            server: server, page: server.url("/page.html"), window: window
        ) {
            pool.unload(tab.id)
            return pool.webView(for: tab, space: space, desktop: false)
        }

        // The control script is what says the page finished at all — without
        // it, "the blocked script did not run" is also what a page that never
        // loaded looks like.
        XCTAssertTrue(
            probe.pageLoaded, "the page never loaded, so nothing here is measuring rules")
        XCTAssertTrue(server.wasRequested("/allowed.js"), "the control resource was served")
        XCTAssertFalse(
            probe.blockedArrived,
            "declarativeNetRequest did not block a request its own rule matches, in "
                + "\(probe.attempts) passes")
        XCTAssertFalse(
            probe.serverWasAsked,
            "the request reached the server, so it was not blocked — it merely failed")
    }

    /// The order people actually install in: a tab is already open, and *then*
    /// a blocker arrives.
    ///
    /// This is the case the first version of this feature got wrong. The
    /// content script appeared — WebKit injects those into whatever is open —
    /// so it looked as though the extension was working, while its blocking
    /// rules did nothing at all, because a compiled rule list only reaches a
    /// page through the configuration its web view was built with. The fix is
    /// to rebuild the views; this is what says so.
    func testInstallingABlockerAffectsATabThatWasAlreadyOpen() async throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        server.serve("/zen-blocked-resource.js", javascript: "window.zenBlockedArrived = true;")
        server.serve("/allowed.js", javascript: "window.zenAllowedArrived = true;")
        server.serve("/page.html", html: server.probePage)

        let host = makeHost()
        let state = makeState()
        let pool = WebViewPool()
        pool.state = state
        pool.extensions = host
        host.start(state: state, pool: pool)

        // A tab, open and loaded, with nothing installed.
        let space = try XCTUnwrap(state.activeSpace)
        let tab = try XCTUnwrap(state.newTab(url: server.url("/page.html")))
        let first = pool.webView(for: tab, space: space, desktop: false)
        let window = UIWindow(frame: .init(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(first)
        window.isHidden = false
        first.load(URLRequest(url: server.url("/page.html")))
        for _ in 0..<200 {
            if let done = try? await first.evaluateJavaScript("window.zenBlockedArrived === true")
                as? Bool, done
            {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(
            server.wasRequested("/zen-blocked-resource.js"),
            "with nothing installed the resource has to arrive, or the probe is meaningless")

        // Now install the blocker, exactly as Settings does.
        let generationBefore = state.webViewGeneration
        let record = try install("zen-blocker", into: host)
        host.installedChanged()
        await waitForLoad(host, record.id)
        // Give the rebuild request a turn of the runloop.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertGreaterThan(
            state.webViewGeneration, generationBefore,
            "loading an extension has to invalidate the web views, or a tab that was already "
                + "open keeps a configuration with no rule list in it")
        XCTAssertFalse(
            pool.isLoaded(tab.id), "the rebuild starts by dropping the view the pool holds")

        // What SwiftUI does next: build the pane again, which asks the pool for
        // a new web view — this time with the controller's rules on it.
        let second = pool.webView(for: tab, space: space, desktop: false)
        XCTAssertFalse(second === first, "the pool handed back the same stale view")
        first.removeFromSuperview()

        let probe = await probeBlocking(
            server: server, page: server.url("/page.html"), window: window
        ) {
            pool.unload(tab.id)
            return pool.webView(for: tab, space: space, desktop: false)
        }
        XCTAssertTrue(probe.pageLoaded, "the rebuilt view never loaded the page")
        XCTAssertFalse(
            probe.blockedArrived,
            "the blocker was installed and the tab still loaded the blocked resource, in "
                + "\(probe.attempts) passes")
    }

    /// The bundled fixtures have to be in the *app* bundle, not only the test
    /// bundle, or "Install the two test extensions" is a button that fails.
    func testTheBundledFixturesAreShippedInTheApp() throws {
        for name in ExtensionStore.bundledFixtureNames {
            XCTAssertNotNil(
                ExtensionStore.bundledFixtureURL(name, bundle: .main),
                "\(name) is missing from the app bundle")
        }
    }
}
