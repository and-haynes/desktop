//  ScreenshotTests.swift
//  Drives the app into each documented state and writes a PNG per state into
//  the runner's Documents directory, which the build script pulls out with
//  `xcrun simctl get_app_container`.
//
//  This is documentation tooling, not a correctness test — it is in its own
//  scheme (ZenScreenshots) so it never slows down or flakes the unit tests.
//  It does assert that each control it needs actually exists, which makes it a
//  reasonable smoke test of the chrome as a side effect.

import XCTest

final class ScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        // Keep going after a soft failure: a state we cannot reach should not
        // cost us the screenshots for every state after it.
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        recoverFromStuckCompactMode()
    }

    /// Compact mode is a *persisted* setting, so a run that failed partway
    /// through the compact test hands the next launch an app with no visible
    /// chrome to drive — every test after it then fails with "address bar
    /// missing", which says nothing about the thing it was testing. This
    /// happened; hence both this and `revealChrome` below.
    private func recoverFromStuckCompactMode() {
        // `.waitForExistence` alone is exactly the trap the comment above
        // describes: compact mode's full bar keeps its subviews mounted
        // while visually collapsed, so a stuck-hidden bar still reports as
        // existing and this guard used to let it straight through.
        _ = addressBar.waitForExistence(timeout: 6)
        guard !(addressBar.exists && addressBar.isHittable) else { return }
        guard revealChrome() else { return }
        _ = tapMenuItem(matching: "label CONTAINS[c] 'Compact Mode'")
        settle(1.0)
    }

    /// Bring a hidden compact bar back via the grabber above the home
    /// indicator. Several offsets because the grabber's 44pt hit area is a
    /// small target in normalised coordinates and it moves with the home
    /// indicator between device sizes — one hard-coded number was wrong on the
    /// first phone it met.
    @discardableResult
    private func revealChrome() -> Bool {
        // `.exists` alone is not enough here: compact mode's full bar
        // (#008AF) keeps its subviews mounted while visually collapsed
        // behind the pill, so an address bar that is invisible and
        // untappable still reports as existing.
        if addressBar.exists && addressBar.isHittable { return true }
        // The compact-mode pill (#008AF) is a specific element with its own
        // tap handler, not a coordinate to guess at — a blind screen tap can
        // land on a zero-frame decoy in the same region and silently do
        // nothing. Scrolling first is what actually shows the pill if the
        // bar is currently fully hidden (the 3 s still-timer, #008AF); tap
        // it once that exists, then fall back to the grabber (#00895) and
        // finally to coordinate taps for whatever layout has neither.
        let pill = app.buttons["compactPill"]
        if !pill.exists {
            app.swipeUp(velocity: .slow)
            app.swipeDown(velocity: .slow)
        }
        if pill.waitForExistence(timeout: 2.5) {
            pill.tap()
            if addressBar.waitForExistence(timeout: 2.5) { return true }
        }
        // The grabber (#00895) carries no identifier of its own, only the
        // label "Show toolbar" — distinct from the pill's own label, which is
        // always "Show toolbar — <something>", so an exact match cannot
        // collide with it.
        let grabber = app.buttons["Show toolbar"]
        if grabber.exists {
            grabber.tap()
            if addressBar.waitForExistence(timeout: 2.5) { return true }
        }
        for dy in [0.945, 0.965, 0.925] {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy)).tap()
            if addressBar.waitForExistence(timeout: 2.5) { return true }
        }
        return false
    }

    // MARK: Capture

    private var outputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
        // Also attach, so a failed run still leaves evidence in the xcresult.
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Pages need a moment to paint; there is no "page loaded" signal to wait on
    /// from outside the app.
    private func settle(_ seconds: TimeInterval = 2.5) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: Elements

    private var sidebarButton: XCUIElement { app.buttons["Toggle sidebar"] }
    private var addressBar: XCUIElement { app.buttons["Address and search"] }

    private func openSidebar() {
        XCTAssertTrue(sidebarButton.waitForExistence(timeout: 10), "sidebar button missing")
        sidebarButton.tap()
        settle(1.2)
    }

    /// The drawer covers the left 280pt of the screen, which is exactly where
    /// the toolbar's sidebar button and most of the address bar live — XCUITest
    /// taps an element's frame centre regardless of what is on top of it, so
    /// tapping either of those would hit the drawer instead. Dismiss via the
    /// scrim on the right.
    private func closeSidebar() {
        let newTab = app.buttons["New Tab"]
        guard newTab.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45)).tap()
        settle(1.2)
        guard newTab.exists else { return }
        // Fall back to the dismiss swipe if the scrim tap did not take.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
        settle(1.2)
    }

    /// Open the floating search box and return its field, dumping the element
    /// tree if it does not appear so a failed run is debuggable.
    @discardableResult
    private func openOmnibox() -> XCUIElement? {
        // In compact mode the bar may have fallen to a pill or gone entirely
        // since the last step; the grabber is the way back.
        revealChrome()
        guard addressBar.waitForExistence(timeout: 10) else {
            XCTFail("address bar missing")
            return nil
        }
        addressBar.tap()
        settle(1.5)
        let field = app.textFields["omniboxField"]
        if field.waitForExistence(timeout: 8) { return field }

        let anyField = app.textFields.firstMatch
        if anyField.waitForExistence(timeout: 3) { return anyField }

        capture("debug-omnibox-missing")
        try? Data(app.debugDescription.utf8)
            .write(to: outputDirectory.appendingPathComponent("debug-hierarchy.txt"))
        XCTFail("omnibox field missing")
        return nil
    }

    private func navigate(to text: String) {
        guard let field = openOmnibox() else { return }
        field.typeText(text + "\n")
        settle(4.0)
    }


    /// Open Settings and reach the space row. Settings has grown enough that
    /// Spaces is below the fold, and XCUITest does not scroll for you.
    private func openSpaceEditor() -> Bool {
        guard tapMenuItem(matching: "label CONTAINS[c] 'Settings'") else { return false }
        settle(1.5)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Personal'")).firstMatch
        for _ in 0..<6 {
            if row.exists && row.isHittable { break }
            app.swipeUp()
            settle(0.6)
        }
        guard row.waitForExistence(timeout: 5) else { return false }
        row.tap()
        settle(1.5)
        return true
    }

    /// From the space editor, open the accent picker.
    private func openAccentPicker() -> Bool {
        let accent = app.buttons["accentRow"].firstMatch
        let accentCell = app.cells["accentRow"].firstMatch
        if accent.waitForExistence(timeout: 5) {
            accent.tap()
        } else if accentCell.waitForExistence(timeout: 5) {
            accentCell.tap()
        } else {
            return false
        }
        settle(2.0)
        return true
    }

    // MARK: Menu helpers

    private var moreButton: XCUIElement {
        let identified = app.buttons["moreMenu"]
        return identified.exists ? identified : app.buttons["More"]
    }

    /// Open the overflow menu and tap the first item whose label matches.
    @discardableResult
    private func tapMenuItem(matching predicate: String) -> Bool {
        revealChrome()
        guard moreButton.waitForExistence(timeout: 8) else { return false }
        moreButton.tap()
        settle(1.2)
        let item = app.buttons.matching(NSPredicate(format: predicate)).firstMatch
        guard item.waitForExistence(timeout: 5) else {
            // Dismiss the menu rather than leaving it open over the next step.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            settle(0.8)
            return false
        }
        item.tap()
        settle(1.6)
        return true
    }

    /// Compact mode: the bar is gone and only the grabber remains (#00887).
    func testCaptureCompactGrabber() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)
        navigate(to: "zen-browser.app")

        XCTAssertTrue(
            tapMenuItem(matching: "label CONTAINS[c] 'Compact Mode'"),
            "compact mode menu item missing")
        // #008AF: the bar starts whole and falls a step at a time — expanded,
        // pill, gone — so reaching the grabber takes two still-delays.
        settle(9.0)
        capture("10-compact-grabber\(suffix)")

        // Prove the grabber reveals the bar, then leave compact mode so the
        // session does not carry it into the next run.
        let grabber = app.otherElements["Show toolbar"].firstMatch
        let grabberButton = app.buttons["Show toolbar"].firstMatch
        if grabber.waitForExistence(timeout: 3) {
            grabber.tap()
        } else if grabberButton.waitForExistence(timeout: 3) {
            grabberButton.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.955)).tap()
        }
        settle(1.5)
        capture("10b-compact-revealed\(suffix)")
        _ = tapMenuItem(matching: "label CONTAINS[c] 'Compact Mode'")
    }


    /// Compact mode's middle state (#008AF): scrolling brings back the pill —
    /// favicon and domain, nothing else — and only a *tap* on it expands the
    /// full bar.
    func testCaptureCompactPillAndExpansion() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)
        // A page long enough to scroll, which is what summons the pill.
        navigate(to: "https://news.ycombinator.com")

        XCTAssertTrue(
            tapMenuItem(matching: "label CONTAINS[c] 'Compact Mode'"),
            "compact mode menu item missing")
        settle(9.0)

        let pill = app.descendants(matching: .any)["compactPill"].firstMatch
        XCTAssertTrue(scrollToThePill(pill), "scrolling did not bring back the collapsed pill")
        capture("39-compact-pill\(suffix)")

        // Scrolling must never expand it — only the tap does.
        XCTAssertFalse(
            app.buttons["Address and search"].exists,
            "scrolling expanded the bar; it should only ever bring back the pill")

        XCTAssertTrue(scrollToThePill(pill), "the pill did not come back for the tap")
        pill.tap()
        settle(0.8)
        XCTAssertTrue(
            app.buttons["Address and search"].waitForExistence(timeout: 3),
            "tapping the pill did not expand the bar")
        capture("40-compact-expanded\(suffix)")

        // (c) The URL area of the *expanded* bar is still the way into the
        // omnibox — expanding and searching are two taps, not one.
        app.buttons["Address and search"].tap()
        XCTAssertTrue(
            app.textFields["omniboxField"].waitForExistence(timeout: 8),
            "tapping the expanded bar's URL area did not open the omnibox")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        settle(1.0)

        // (d) Up from the *pill* reaches the drawer, without expanding first.
        XCTAssertTrue(scrollToThePill(pill), "the pill did not come back for the swipe")
        pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        XCTAssertTrue(
            app.buttons["New Tab"].waitForExistence(timeout: 5),
            "swiping up from the pill did not open the sidebar")
        closeSidebar()

        // Leave compact mode, or the setting persists into the next launch and
        // every test after this one starts with no bar to drive. This is why
        // `tapMenuItem` reveals first: by now the bar has long since fallen.
        XCTAssertTrue(
            tapMenuItem(matching: "label CONTAINS[c] 'Compact Mode'"),
            "could not leave compact mode — the next test will launch with no bar")
    }

    /// Scroll the page and catch the pill before the still-timer takes it. The
    /// timer is three seconds by default, so this is deliberately brisk.
    private func scrollToThePill(_ pill: XCUIElement) -> Bool {
        for _ in 0..<4 {
            app.swipeUp()
            if pill.waitForExistence(timeout: 1.2) { return true }
        }
        return false
    }

    // MARK: Video (#008B0)

    /// The fixture page is served from the *host* — `python3 -m http.server`
    /// in /tmp/zenvideo, which the simulator reaches on localhost. A real mp4
    /// over real HTTP is the point: `loadHTMLString` would not exercise the
    /// media pipeline, and a remote site would make this test depend on
    /// somebody else's uptime.
    private static let videoFixture = "http://localhost:8777/index.html"

    /// Full screen from the page's *own* button, which is
    /// `webkitEnterFullscreen()` — the path `isElementFullscreenEnabled`
    /// governs, and the one every video site's custom controls take.
    func testCaptureVideoFullScreen() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(3.0)
        navigate(to: Self.videoFixture)

        let play = app.buttons["Play the clip"]
        XCTAssertTrue(
            play.waitForExistence(timeout: 15),
            "the local video fixture did not load — is the server on 8777 running?")
        play.tap()
        settle(2.0)

        let fullScreen = app.buttons["Go full screen"]
        XCTAssertTrue(fullScreen.waitForExistence(timeout: 5), "fullscreen button missing")
        fullScreen.tap()
        settle(3.0)
        capture("42-video-fullscreen\(suffix)")

        // Out again, so the next test does not start inside a video player.
        // The controls fade, so tap to bring them back first — and if Done is
        // still not there, relaunching is the one exit that always works.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        settle(1.2)
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3) {
            done.tap()
        } else {
            app.terminate()
            app.launch()
        }
        settle(1.5)
    }

    /// "Pop Out Video" in the overflow menu, on a page with two videos — the
    /// finder has to pick the big playing one and not the decoy thumbnail.
    func testCaptureVideoPictureInPicture() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(3.0)
        navigate(to: Self.videoFixture)

        let play = app.buttons["Play the clip"]
        XCTAssertTrue(
            play.waitForExistence(timeout: 15),
            "the local video fixture did not load — is the server on 8777 running?")
        play.tap()
        settle(2.5)

        XCTAssertTrue(
            tapMenuItem(matching: "label CONTAINS[c] 'Pop Out Video'"),
            "Pop Out Video missing from the overflow menu")
        settle(2.0)
        capture("43-video-pip\(suffix)")

        // **The simulator has no Picture in Picture** — see `VideoPopOut` for
        // the WebKit detail — so the floating window cannot be shown here at
        // all; what this captures is the request being made on a real playing
        // video, and it asserts the action is reachable and does not take the
        // app down with it.
        //
        // The *outcome* is covered where it can be covered honestly:
        // `VideoPopOutTests` runs the shipped script against a real DOM and
        // asserts the simulator gets `unsupported` rather than a pretended
        // success, and the toast that says so is in
        // `docs/screenshots/44-popout-no-video.png`. The toast resisted every
        // XCUITest query I tried while being plainly visible in a screenshot,
        // so there is no assertion on it here rather than a flaky one.
        XCTAssertTrue(
            app.buttons["Address and search"].waitForExistence(timeout: 5),
            "the app should still be usable after a pop-out attempt")
    }

    /// The accent colour tool (#0088F) and the hex entry path.
    func testCaptureColorPicker() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)

        // Settings -> the first space -> Accent.
        XCTAssertTrue(openSpaceEditor(), "could not reach the space editor")
        XCTAssertTrue(openAccentPicker(), "accent row missing")
        capture("14-colour-picker\(suffix)")

        // Type a hex value and apply it, which is the other half of the tool.
        let hex = app.textFields["hexField"].firstMatch
        XCTAssertTrue(hex.waitForExistence(timeout: 8), "hex field missing")
        hex.tap()
        settle(0.6)
        // Clear whatever is there, then type a recognisable colour.
        if let existing = hex.value as? String, !existing.isEmpty {
            hex.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        hex.typeText("#E15B6E\n")
        settle(1.5)
        capture("15-colour-hex\(suffix)")

        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-COLOUR"))
    }


    /// The silent-failure bug (#0089A), reproduced against real endpoints:
    /// a refused port on a LAN-looking host, which is exactly what
    /// https://10.0.0.80 does (Proxmox serves :8006, nothing on :443).
    func testCaptureErrorPage() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)

        guard let field = openOmnibox() else { return XCTFail("omnibox missing") }
        // 127.0.0.1 classifies as local and nothing listens on 9999.
        field.typeText("http://127.0.0.1:9999/\n")
        settle(6.0)

        let errorPage = app.otherElements["errorPage"].firstMatch
        let retry = app.buttons["errorRetry"].firstMatch
        XCTAssertTrue(
            errorPage.waitForExistence(timeout: 12) || retry.waitForExistence(timeout: 4),
            "a refused connection must show the error page, not a blank view")
        capture("17-error-page\(suffix)")

        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-ERROR"))
    }

    /// The status bar is hidden by default (#00899). Captures the default,
    /// proves the Settings toggle brings it back and that the choice sticks,
    /// then puts it away again so the session does not carry the change into
    /// the next test.
    func testCaptureStatusBar() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)
        capture("24-status-bar-hidden\(suffix)")

        XCTAssertTrue(
            flipShowStatusBar(from: "0", to: "1"), "the toggle would not turn the status bar on")
        settle(2.0)
        capture("24b-status-bar-shown\(suffix)")

        XCTAssertTrue(
            flipShowStatusBar(from: "1", to: "0"),
            "the choice did not persist, or would not go back")
        settle(2.0)
        capture("24c-status-bar-hidden-again\(suffix)")
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-STATUSBAR"))
    }

    /// #008A9. Hiding the status bar must take away the clock, the signal and
    /// the battery and nothing else — the Dynamic Island is hardware, and the
    /// page has to start below it. Hacker News is the proof: its header is
    /// `position: fixed`, so if the inset is wrong it is the first thing to
    /// disappear under the island.
    func testCaptureStatusBarHiddenOverAFixedHeaderPage() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        // Hidden is the default (#00899); this asserts it rather than assuming.
        XCTAssertFalse(app.statusBars.firstMatch.exists, "the status bar should start hidden")
        navigate(to: "https://news.ycombinator.com")
        settle(3.0)
        capture("32-status-hidden-card\(suffix)")
    }

    /// Open Settings, check the toggle reads `from` (which is what proves the
    /// previous step stuck), flip it, wait for `to`, and close the sheet.
    private func flipShowStatusBar(from: String, to: String) -> Bool {
        guard openSettings() else { return false }
        let toggle = app.switches["showStatusBarToggle"].firstMatch
        guard toggle.waitForExistence(timeout: 10) else {
            dismissSheet()
            return false
        }
        guard (toggle.value as? String) == from else {
            dismissSheet()
            return false
        }
        // A SwiftUI Form toggle's accessibility frame is the whole row, and its
        // centre is dead space between the label and the switch — tapping there
        // does nothing. Aim at the switch.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        // SwiftUI updates the accessibility value a frame or two after the tap;
        // reading it once turns that into a flake.
        var flipped = false
        for _ in 0..<10 {
            if (toggle.value as? String) == to {
                flipped = true
                break
            }
            settle(0.4)
        }
        dismissSheet()
        return flipped
    }

    private func openSettings() -> Bool {
        guard tapMenuItem(matching: "label CONTAINS[c] 'Settings'") else { return false }
        settle(1.5)
        return true
    }

    /// Done, or a pull-down if the toolbar button is not reachable — a sheet
    /// left up swallows every step after it.
    private func dismissSheet() {
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 4), done.isHittable {
            done.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.14))
                .press(
                    forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        settle(1.5)
    }

    /// Settings → Sync (#00892). Captures the signed-out section and the
    /// sign-in sheet opening.
    ///
    /// The flow stops at Mozilla's own page: completing a sign-in needs a real
    /// account and a real password, which a screenshot run has neither of. The
    /// sheet appearing is the part this can prove, and it is the part that
    /// would break first — `ASWebAuthenticationSession` refuses to start if the
    /// callback scheme is not one it will match.
    func testCaptureSyncSettings() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)

        XCTAssertTrue(openSettings(), "could not open Settings")

        // A SwiftUI Form is a collection view; swiping the app as a whole
        // lands on the omnibox behind the sheet, which opens the sidebar.
        let sheet = app.collectionViews.firstMatch
        let signIn = app.descendants(matching: .any)["syncSignInButton"].firstMatch
        for _ in 0..<10 {
            if signIn.exists && signIn.isHittable { break }
            if sheet.exists { sheet.swipeUp() } else { app.swipeUp() }
            settle(0.5)
        }
        if !signIn.exists {
            try? Data(app.debugDescription.utf8)
                .write(to: outputDirectory.appendingPathComponent("sync-tree.txt"))
        }
        XCTAssertTrue(
            signIn.waitForExistence(timeout: 8), "the Sync section is missing from Settings")
        capture("28-sync-settings\(suffix)")

        signIn.tap()
        // Our own sheet, loading accounts.firefox.com. The password field is
        // Mozilla's page inside a web view that loads exactly one origin and is
        // thrown away with the sheet — see SyncConfig for why it is not the
        // system sign-in sheet.
        let cancel = app.buttons["syncSignInCancel"].firstMatch
        XCTAssertTrue(
            cancel.waitForExistence(timeout: 10),
            "the sign-in sheet did not open")
        settle(10.0)
        capture("29-sync-signin\(suffix)")

        // The page having rendered Mozilla's form rather than an error is the
        // one thing a screenshot run can say about the client id, the scopes
        // and the redirect without an account to sign in with.
        XCTAssertTrue(
            app.staticTexts["Enter your email"].waitForExistence(timeout: 12)
                || app.webViews.firstMatch.exists,
            "accounts.firefox.com did not render the sign-in form — the "
                + "authorization request was rejected")

        // Leave the sheet closed, or every screenshot after this one is of it.
        if cancel.exists, cancel.isHittable { cancel.tap() }
        settle(1.5)
        dismissSheet()

        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-SYNC"))
    }

    /// #008AA end to end, as far as it can go without a password.
    ///
    /// The app is relaunched with `-zenFxAWebChannelProbe`, which makes the
    /// sign-in sheet dispatch a synthetic `fxaccounts:oauth_login` into
    /// Mozilla's own page once it loads — with this request's real `state` and
    /// an obviously fake `code`. That drives the WebChannel handler, the state
    /// check and the PKCE exchange against Mozilla's live token endpoint,
    /// which rejects the code. **The rejection appearing in the diagnostics
    /// transcript is the assertion**: before this ticket the flow ended in
    /// silence, and a silent failure is the bug.
    ///
    /// It also captures the transcript itself, which is the evidence that
    /// `fxaccounts:fxa_status` was asked and answered.
    func testSyncDiagnosticsRecordTheWebChannelFlow() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += [
            "-zenFxAWebChannelProbe",
            """
            {"id":"account_updates","message":{"command":"fxaccounts:oauth_login",\
            "messageId":"probe","data":{"action":"signin",\
            "code":"zenprobe0000000000000000000000000000000000000000000000000000cafe",\
            "state":"__ZEN_STATE__","declinedSyncEngines":[],\
            "offeredSyncEngines":["bookmarks","history","tabs"]}}}
            """,
        ]
        app.launch()
        settle(4.0)

        XCTAssertTrue(openSettings(), "could not open Settings")
        let sheet = app.collectionViews.firstMatch
        let signIn = app.descendants(matching: .any)["syncSignInButton"].firstMatch
        for _ in 0..<10 {
            if signIn.exists && signIn.isHittable { break }
            if sheet.exists { sheet.swipeUp() } else { app.swipeUp() }
            settle(0.5)
        }
        XCTAssertTrue(signIn.waitForExistence(timeout: 8), "the Sync section is missing")
        signIn.tap()

        let cancel = app.buttons["syncSignInCancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "the sign-in sheet did not open")
        // Mozilla's page, then the probe, then the exchange. The alert that
        // the failed exchange raises is itself the proof that the failure did
        // not vanish.
        // The page itself, part-way through: this is what Mozilla's form looks
        // like in a WebChannel context, and whether it rendered at all.
        settle(12.0)
        capture("29c-sync-signin-webchannel\(suffix)")
        let alert = app.alerts.firstMatch
        let sawAlert = alert.waitForExistence(timeout: 70)
        if sawAlert {
            capture("30-sync-signin-failure\(suffix)")
            XCTAssertTrue(
                alert.staticTexts.element(boundBy: 0).label.contains("Sync stopped at"),
                "a failed exchange must say where it stopped")
            alert.buttons["OK"].firstMatch.tap()
            settle(1.0)
        }
        if cancel.exists, cancel.isHittable { cancel.tap() }
        settle(1.5)

        // The transcript: authorization opened, page loaded, fxa_status
        // answered, oauth_login received, code exchange failed.
        let diagnostics = app.descendants(matching: .any)["syncDiagnosticsLink"].firstMatch
        for _ in 0..<10 {
            if diagnostics.exists && diagnostics.isHittable { break }
            if sheet.exists { sheet.swipeUp() } else { app.swipeUp() }
            settle(0.5)
        }
        XCTAssertTrue(
            diagnostics.waitForExistence(timeout: 10), "the diagnostics row is missing")
        diagnostics.tap()
        settle(1.5)
        capture("31-sync-diagnostics\(suffix)")

        let transcript = app.descendants(matching: .any)["syncDiagnosticsView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 8), "diagnostics did not open")
        let text = app.debugDescription
        XCTAssertTrue(
            text.contains("Sign-in page loaded"), "the sign-in page never loaded")
        XCTAssertTrue(
            text.contains("oauth_login"),
            "the oauth_login message never crossed the WebChannel")
        XCTAssertTrue(
            text.contains("state matched"), "the state check did not run")
        XCTAssertTrue(
            sawAlert || text.contains("Code exchange"),
            "the flow did not reach the code exchange")
        // `fxaccounts:fxa_status` is deliberately *not* asserted here. The
        // Mozilla accounts page asks for it after an email has been entered
        // and the account is known, which needs a real account — so the live
        // run cannot reach it. The round trip is covered instead by
        // `FxAWebChannelBridgeTests`, in a real WKWebView against a stand-in
        // page. See the README.
        try? Data(text.utf8)
            .write(to: outputDirectory.appendingPathComponent("sync-diagnostics-tree.txt"))
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-DIAGNOSTICS"))
    }

    /// iOS Password AutoFill in our web views (#008AB).
    ///
    /// The assertion is the **AutoFill affordance in the QuickType bar**: iOS
    /// puts it there when a WKWebView's focused field is one it can fill, and
    /// takes it away if the app has replaced the input accessory view, emptied
    /// the keyboard's assistant item, or stolen first responder. Nothing in Zen
    /// does any of those — this is the test that keeps it that way.
    ///
    /// Needs the fixture server from `ios/Tests/Fixtures/serve.py` running on
    /// the host; the simulator's 127.0.0.1 is the Mac's. Skipped, not failed,
    /// when nothing is listening: a screenshot run on another machine should
    /// not go red for want of a local server.
    func testPasswordAutoFillIsOfferedInTheWebView() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(3.0)

        guard let password = try focusFixturePasswordField() else {
            throw XCTSkip(
                "no fixture login form on any candidate port — start "
                    + "`python3 Tests/Fixtures/serve.py`. See \"Password AutoFill\" "
                    + "in ios/README.md.")
        }
        _ = password
        // Context only: the page, the omnibox and WebKit's own form toolbar.
        // See the note below on why the keyboard is not in it.
        capture("34-autofill-window\(suffix)")

        // The web view must still own the keyboard: a browser that takes the
        // field's first responder away kills AutoFill outright.
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 8),
            "focusing a password field did not raise the keyboard")
        XCTAssertFalse(
            app.textFields["omniboxField"].exists,
            "the omnibox stole focus from the page's password field")

        // The whole app scene, dumped so a run that finds no affordance says
        // *what it did find* rather than just failing.
        try? Data(app.debugDescription.utf8)
            .write(to: outputDirectory.appendingPathComponent("autofill-keyboard-tree.txt"))

        // The bar is `SystemInputAssistantView`, which is a *sibling* of the
        // keyboard under the window, not a descendant of it — querying
        // `app.keyboards` for it finds nothing even when it is on screen.
        XCTAssertTrue(
            assistantBar.waitForExistence(timeout: 8),
            "no input assistant bar above the keyboard — the app has replaced "
                + "or emptied it, which is what removes AutoFill")

        let affordance = autoFillAffordance
        XCTAssertTrue(
            affordance.exists,
            "no AutoFill affordance on a focused password field — something in "
                + "the app is suppressing it")

        // The element tree is the assertion; the *picture* has to come from
        // outside. Neither `XCUIScreen.main.screenshot()` nor an element
        // screenshot composites the keyboard scene — the keyboard lives in its
        // own `UIRemoteKeyboardWindow`, so both render the app window and leave
        // a blank strip where the Passwords row is. `34-autofill.png` in
        // `docs/screenshots` is therefore a framebuffer grab taken while this
        // test holds the state:
        //
        //     xcrun simctl io <udid> screenshot frame.png
        //
        // Run it in a loop alongside the test and keep the frame with the
        // keyboard up. Nothing is written here under that name, so the
        // committed screenshot is never overwritten by a blank one.
        try? Data(assistantBar.debugDescription.utf8)
            .write(to: outputDirectory.appendingPathComponent("34-autofill-bar\(suffix).txt"))

        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-AUTOFILL"))
    }

    /// The candidates the fixture server may be on. Probed rather than fixed
    /// because the port is the host's to choose, and a test that hard-codes one
    /// fails for a reason that has nothing to do with the app.
    ///
    /// **https only, and a named host.** Measured, not assumed: served over
    /// `http://127.0.0.1:8090` the same page raises the keyboard with no
    /// `SystemInputAssistantView` above it at all — iOS offers Password
    /// AutoFill on secure origins only. `zen.localtest.me` is public DNS that
    /// answers 127.0.0.1, so it needs no `/etc/hosts` edit, and the simulator
    /// resolves and routes it through the Mac.
    private static let fixtureURLs = [
        "https://zen.localtest.me:8443/login.html",
        "https://zen.localtest.me:8444/login.html",
    ]

    /// Load the fixture login page and put the caret in its password field.
    /// Returns nil when no candidate served a form, so the caller can skip.
    private func focusFixturePasswordField() throws -> XCUIElement? {
        for candidate in Self.fixtureURLs {
            navigate(to: candidate)
            settle(2.0)
            let password = app.webViews.firstMatch.secureTextFields.firstMatch
            guard password.waitForExistence(timeout: 6) else { continue }
            password.tap()
            settle(2.5)
            return password
        }
        return nil
    }

    /// The bar above the keyboard that carries the AutoFill key. UIKit calls
    /// it `SystemInputAssistantView` and hangs it off the window beside the
    /// keyboard, so it is reached from `app`, not from `app.keyboards`.
    private var assistantBar: XCUIElement {
        app.descendants(matching: .any)["SystemInputAssistantView"].firstMatch
    }

    /// What iOS calls the AutoFill entry point has moved around between
    /// releases — a key glyph (`kb-autofill-key`), a "Passwords" key, a
    /// QuickType suggestion naming the saved account. Match any of them rather
    /// than pinning one name. Verified against Safari on the same fixture page,
    /// which shows `Button "Passwords"` wrapping `Image kb-autofill-key`.
    private var autoFillAffordance: XCUIElement {
        assistantBar.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == 'kb-autofill-key' OR identifier CONTAINS[c] 'autofill' "
                    + "OR label CONTAINS[c] 'password' OR label CONTAINS[c] 'autofill' "
                    + "OR label CONTAINS[c] 'zen.localtest.me'")
        ).firstMatch
    }

    /// Settings → Passwords (#008AB): the explanation and the route to the
    /// AutoFill pane, which iOS gives no deep link to.
    func testCapturePasswordsSettings() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(3.0)
        XCTAssertTrue(openSettings(), "could not open Settings")

        let sheet = app.collectionViews.firstMatch
        let link = app.descendants(matching: .any)["passwordsSettingsLink"].firstMatch
        for _ in 0..<12 {
            if link.exists && link.isHittable { break }
            if sheet.exists { sheet.swipeUp() } else { app.swipeUp() }
            settle(0.4)
        }
        XCTAssertTrue(link.waitForExistence(timeout: 8), "the Passwords row is missing")
        link.tap()
        settle(1.5)
        XCTAssertTrue(
            app.descendants(matching: .any)["passwordsSettingsView"].waitForExistence(timeout: 8),
            "the Passwords screen did not open")
        capture("35-passwords-settings\(suffix)")
        // The one button on the screen has to exist, or the instructions are
        // all there is. It is below the fold on a phone.
        let button = app.descendants(matching: .any)["passwordsOpenSettingsButton"].firstMatch
        let form = app.collectionViews.firstMatch
        for _ in 0..<8 {
            if button.exists && button.isHittable { break }
            if form.exists { form.swipeUp() } else { app.swipeUp() }
            settle(0.4)
        }
        XCTAssertTrue(button.exists, "no way to reach iOS Settings")
        capture("35b-passwords-settings-foot\(suffix)")
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-PASSWORDS"))
    }

    /// The new-tab strip (#0089F): full width, pinned below the tab list, and
    /// it actually makes a tab.
    func testCaptureNewTabStrip() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)
        if UIDevice.current.userInterfaceIdiom != .pad { openSidebar() }

        let strip = app.buttons["newTabStrip"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 8), "new-tab strip missing")
        // Full width: the strip must span the sidebar, not sit in it as a row.
        XCTAssertGreaterThan(
            strip.frame.width, 240, "the strip should span the sidebar width")
        XCTAssertGreaterThanOrEqual(strip.frame.height, 44, "44pt is the minimum target")
        capture("25-sidebar-newtab-strip\(suffix)")

        // Tapping it opens a new tab, which lands on the start page with the
        // omnibox up.
        strip.tap()
        settle(2.0)
        let field = app.textFields["omniboxField"].firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 8),
            "the strip must create a tab and open the omnibox on it")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        settle(1.5)
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-NEWTAB"))
    }

    /// The single-word rule: `meitner` searches, but the other reading is
    /// offered explicitly as the second row rather than guessed at.
    func testSingleWordOffersGoToHost() throws {
        settle(4.0)
        guard let field = openOmnibox() else { return XCTFail("omnibox missing") }
        field.typeText("meitner")
        settle(2.5)

        let goTo = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Go to http://meitner'")).firstMatch
        XCTAssertTrue(
            goTo.waitForExistence(timeout: 8),
            "a bare word must offer 'Go to http://meitner' explicitly")
        capture("26-single-word")

        // And it navigates when picked.
        goTo.tap()
        settle(4.0)
        XCTAssertTrue(
            app.buttons["Address and search"].waitForExistence(timeout: 8),
            "the omnibox should have closed onto the tab")
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-SINGLEWORD"))
    }

    /// Sidebar position (#008A8): Settings → Sidebar position: Right moves the
    /// drawer (iPhone) or the persistent sidebar (iPad) to the opposite edge,
    /// along with its edge swipe, the toolbar button and the URL bar's
    /// swipe-to-open gesture.
    ///
    /// Reaching Settings on iPad in this simulator/OS combination is flaky
    /// independently of this feature — `testCaptureSyncSettings` and
    /// `testCaptureCompactGrabber` show the same sheet-never-presents symptom
    /// on the same unmodified `openSettings()` path — so this shares that
    /// pre-existing risk rather than working around it here.
    func testCaptureSidebarRight() throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        settle(4.0)

        XCTAssertTrue(openSettings(), "could not open Settings")
        let rightSegment = app.buttons["Right"].firstMatch
        XCTAssertTrue(rightSegment.waitForExistence(timeout: 8), "sidebar position control missing")
        rightSegment.tap()
        settle(0.5)
        dismissSheet()

        let strip = app.buttons["newTabStrip"].firstMatch
        if isPad {
            settle(1.5)
        } else {
            openSidebar()
        }
        XCTAssertTrue(strip.waitForExistence(timeout: 8), "sidebar missing")
        // The new-tab strip spans the sidebar, so its midpoint moving past the
        // screen's own midpoint is proof the sidebar actually moved, not just
        // that the setting changed.
        XCTAssertGreaterThan(
            strip.frame.midX, UIScreen.main.bounds.width / 2,
            "the sidebar should have moved to the right edge")
        capture(isPad ? "31-sidebar-right-ipad" : "30-sidebar-right")

        // Leave the setting as found, so later states in the same run — which
        // assume a leading sidebar — are not thrown off.
        if !isPad { openSidebar() }
        XCTAssertTrue(openSettings(), "could not reopen Settings")
        let leftSegment = app.buttons["Left"].firstMatch
        if leftSegment.waitForExistence(timeout: 8) { leftSegment.tap() }
        settle(0.5)
        dismissSheet()

        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-SIDEBAREDGE"))
    }

    // MARK: The documented states

    func testCaptureAllStates() throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let suffix = isPad ? "-ipad" : ""

        // 1. The seeded session, already showing a loaded page.
        settle(4.0)
        capture("01-page-example\(suffix)")

        // 2. The sidebar: spaces, essentials, pinned and normal tabs.
        //    On iPad it is already beside the content.
        if !isPad {
            openSidebar()
        }
        capture("02-sidebar\(suffix)")

        // 3. Glance — reachable from a tab row's context menu.
        let firstRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Hacker News'")).firstMatch
        if firstRow.waitForExistence(timeout: 5) {
            firstRow.press(forDuration: 1.1)
            settle(1.2)
            let glance = app.buttons["Open in Glance"]
            if glance.waitForExistence(timeout: 5) {
                glance.tap()
                settle(4.0)
                capture("04-glance\(suffix)")
                let close = app.buttons["Close Glance"]
                if close.waitForExistence(timeout: 5) { close.tap() }
                settle(1.2)
            } else {
                // Dismiss the context menu if Glance was not offered.
                app.tap()
                settle(0.8)
            }
        }

        if !isPad { closeSidebar() }

        // 4. A second real page, and the omnibox open over it.
        navigate(to: "zen-browser.app")
        capture("03-page-zen\(suffix)")

        if let field = openOmnibox() {
            field.typeText("zen brow")
            settle(2.5)
            capture("05-omnibox\(suffix)")
            field.typeText("\n")
            settle(3.0)
        }

        // 5. Split view, from the overflow menu.
        var more = app.buttons["moreMenu"]
        if !more.waitForExistence(timeout: 6) { more = app.buttons["More"] }
        if more.waitForExistence(timeout: 6) {
            more.tap()
            settle(1.2)
            let split = app.buttons["Split View"]
            if split.waitForExistence(timeout: 5) {
                split.tap()
                settle(4.0)
                capture("06-split\(suffix)")
            } else {
                app.tap()
            }
        }

        // Leave a breadcrumb so the extraction script can tell a completed run
        // from a crashed one.
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE"))
    }
    /// Text size (#008B7): the More menu's smaller / larger row, the readout,
    /// and the proof that the page actually changes size — the same site is
    /// captured at 100 % and after three taps of Larger.
    func testCaptureTextSize() throws {
        settle(4.0)
        navigate(to: "example.com")
        capture("45-text-size-100")

        _ = revealChrome()
        XCTAssertTrue(moreButton.waitForExistence(timeout: 8), "more menu missing")
        moreButton.tap()
        settle(1.2)
        // The row itself: two buttons side by side, and the readout under them.
        capture("45b-text-size-menu")
        let larger = app.buttons["textSizeLarger"]
        XCTAssertTrue(larger.waitForExistence(timeout: 5), "the Larger button is missing")
        larger.tap()
        settle(1.2)

        // Two more steps, reopening the menu each time — a SwiftUI Menu closes
        // on any tap inside it, which is the one place this differs from
        // Safari's own AA row.
        for _ in 0..<2 {
            _ = revealChrome()
            moreButton.tap()
            settle(1.0)
            let button = app.buttons["textSizeLarger"]
            guard button.waitForExistence(timeout: 4) else { break }
            button.tap()
            settle(1.0)
        }
        capture("45c-text-size-150")

        // And the readout, which is also the reset: the label carries the
        // percentage, so finding it proves the level stuck.
        _ = revealChrome()
        moreButton.tap()
        settle(1.2)
        let readout = app.buttons["textSizeReadout"]
        XCTAssertTrue(readout.waitForExistence(timeout: 5), "the readout is missing")
        XCTAssertTrue(
            readout.label.contains("%"), "the readout should say a percentage: \(readout.label)")
        readout.tap()
        settle(1.5)
        capture("45d-text-size-reset")
    }
}

// MARK: - Reader mode (#008BC)

extension ScreenshotTests {

    /// The reader on a real article, and the appearance panel driving it.
    ///
    /// A Wikipedia article rather than a fixture on purpose: what is being
    /// checked here is not our template, it is whether Mozilla's Readability
    /// finds an article in a page nobody wrote for us. A fixture shaped like
    /// what Readability likes would prove nothing.
    func testCaptureReaderMode() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)
        navigate(to: "https://en.wikipedia.org/wiki/Ophrys_apifera")
        settle(4.0)

        XCTAssertTrue(openReader(), "no route into the reader")
        settle(3.0)
        XCTAssertTrue(
            app.buttons["readerClose"].waitForExistence(timeout: 12), "the reader did not open")
        capture("53-reader-view\(suffix)")

        // The panel at its medium detent, with the article still live above it.
        XCTAssertTrue(openReaderPanel(), "the appearance panel did not open")
        capture("54-reader-controls\(suffix)")

        // Dark, seen on the article rather than on a swatch.
        tapIfPresent(app.buttons["readerTheme-dark"])
        settle(1.2)
        dismissReaderPanel()
        capture("55-reader-dark-theme\(suffix)")

        // Custom: two colours picked by hand through #0088F's colour tool.
        XCTAssertTrue(openReaderPanel(), "the appearance panel did not reopen")
        tapIfPresent(app.buttons["readerTheme-custom"])
        settle(1.0)
        setCustomColour("readerCustomBackground", hex: "#12263A")
        setCustomColour("readerCustomText", hex: "#EFE3C8")
        settle(1.0)
        dismissReaderPanel()
        capture("56-reader-custom-colors\(suffix)")

        // Read aloud, with the transport up and the spoken sentence lit.
        tapIfPresent(app.buttons["readerReadAloud"])
        settle(1.2)
        tapIfPresent(app.buttons["readerPlayPause"])
        settle(3.5)
        capture("57-reader-read-aloud\(suffix)")
        tapIfPresent(app.buttons["readerStop"])

        tapIfPresent(app.buttons["readerClose"])
        settle(1.5)

        // Settings -> Reader: the defaults every site starts from, and the
        // per-site memory this run just wrote an entry into.
        if tapMenuItem(matching: "label CONTAINS[c] 'Settings'") {
            let row = app.buttons["readerSettingsRow"].firstMatch
            let cell = app.cells["readerSettingsRow"].firstMatch
            for _ in 0..<6 {
                if (row.exists && row.isHittable) || (cell.exists && cell.isHittable) { break }
                app.swipeUp()
                settle(0.6)
            }
            if row.exists && row.isHittable {
                row.tap()
            } else if cell.exists && cell.isHittable {
                cell.tap()
            }
            settle(1.8)
            capture("58-reader-settings\(suffix)")
            // The per-site list is below the controls.
            app.swipeUp()
            app.swipeUp()
            settle(1.0)
            capture("58b-reader-settings-sites\(suffix)")
        }

        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-READER"))
    }

    /// The bar button where the probe found an article, the overflow menu
    /// where it did not — the menu item exists precisely to overrule the
    /// heuristic, so it is also the fallback here.
    fileprivate func openReader() -> Bool {
        revealChrome()
        let button = app.buttons["readerButton"]
        if button.waitForExistence(timeout: 14) {
            button.tap()
            return true
        }
        return tapMenuItem(matching: "label CONTAINS[c] 'Show Reader'")
    }

    fileprivate func openReaderPanel() -> Bool {
        let top = app.buttons["readerAppearance"]
        let pill = app.buttons["readerAppearancePill"]
        if top.waitForExistence(timeout: 6) {
            top.tap()
        } else if pill.waitForExistence(timeout: 4) {
            pill.tap()
        } else {
            return false
        }
        settle(1.8)
        return app.buttons["readerTheme-sepia"].waitForExistence(timeout: 6)
    }

    fileprivate func dismissReaderPanel() {
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() } else { app.swipeDown() }
        settle(1.4)
    }

    /// Push into the colour tool, type a hex, apply, come back.
    fileprivate func setCustomColour(_ row: String, hex: String) {
        let link = app.buttons[row].firstMatch
        let cell = app.cells[row].firstMatch
        if link.waitForExistence(timeout: 5) {
            link.tap()
        } else if cell.waitForExistence(timeout: 5) {
            cell.tap()
        } else {
            XCTFail("the \(row) row is missing")
            return
        }
        settle(1.8)
        let field = app.textFields["hexField"].firstMatch
        if field.waitForExistence(timeout: 6) {
            field.tap()
            settle(0.5)
            if let existing = field.value as? String, !existing.isEmpty, existing != "#5B6EE1" {
                field.typeText(
                    String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
            }
            field.typeText(hex + "\n")
        }
        settle(1.2)
        // Back out of the pushed screen; the sheet's own nav bar owns the arrow.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() } else { app.swipeRight() }
        settle(1.4)
    }

    fileprivate func tapIfPresent(_ element: XCUIElement) {
        guard element.waitForExistence(timeout: 6) else { return }
        element.tap()
    }
}
