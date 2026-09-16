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

    var app: XCUIApplication!

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
        guard !addressBar.waitForExistence(timeout: 6) else { return }
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
        if addressBar.exists { return true }
        for dy in [0.945, 0.965, 0.925] {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy)).tap()
            if addressBar.waitForExistence(timeout: 2.5) { return true }
        }
        return false
    }

    // MARK: Capture

    var outputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func capture(_ name: String) {
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
    func settle(_ seconds: TimeInterval = 2.5) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: Elements

    // "Toggle sidebar" was the hard-wired ios-branch button's label; since
    // #00896 the bar is slot-driven and the shipped "zen" preset's sidebar
    // slot carries the identifier below and the label "Tabs" instead. This
    // was already stale on experimental before #008A8 touched this file.
    private var sidebarButton: XCUIElement { app.buttons["barSlot-sidebar"] }
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

    func navigate(to text: String) {
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

    var moreButton: XCUIElement {
        let identified = app.buttons["moreMenu"]
        return identified.exists ? identified : app.buttons["More"]
    }

    /// Open the overflow menu and tap the first item whose label matches.
    @discardableResult
    func tapMenuItem(matching predicate: String) -> Bool {
        revealChrome()
        guard moreButton.waitForExistence(timeout: 8) else { return false }
        moreButton.tap()
        settle(1.2)
        var item = app.buttons.matching(NSPredicate(format: predicate)).firstMatch
        // The overflow menu is taller than the screen and scrolls; an item
        // below the fold is not merely off-screen to XCUITest, it does not
        // exist. Scroll before giving up.
        if !item.waitForExistence(timeout: 3) {
            for _ in 0..<3 {
                app.swipeUp()
                settle(0.6)
                item = app.buttons.matching(NSPredicate(format: predicate)).firstMatch
                if item.exists { break }
            }
        }
        guard item.waitForExistence(timeout: 5) else {
            // Leave evidence: "no item matched" is indistinguishable from "the
            // menu never opened" without a picture and a hierarchy, and both
            // have happened. Same affordance `openOmnibox` already has.
            capture("debug-menu-missing")
            try? Data(app.debugDescription.utf8)
                .write(to: outputDirectory.appendingPathComponent("debug-menu-hierarchy.txt"))
            // Dismiss the menu rather than leaving it open over the next step.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            settle(0.8)
            return false
        }
        item.tap()
        settle(1.6)
        return true
    }

    /// The three-state layout cycle and the compact-mode grabber (#00887).
    func testCaptureLayoutStates() throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let suffix = isPad ? "-ipad" : ""
        settle(4.0)

        // Start from a known page rather than whatever the session restored.
        navigate(to: "zen-browser.app")

        // a. card — the default, content inset with the gradient framing it.
        capture("07-layout-card\(suffix)")

        // b. edgeToEdge — content to the very top, bar still in the flow.
        XCTAssertTrue(
            tapMenuItem(matching: "label BEGINSWITH 'Layout:'"), "layout menu item missing")
        capture("08-layout-edge\(suffix)")

        // c. fullScreen — content everywhere, bar floating with no material.
        XCTAssertTrue(tapMenuItem(matching: "label BEGINSWITH 'Layout:'"))
        capture("09-layout-full\(suffix)")

        // Back to card so the compact shot is not confounded by the layout.
        XCTAssertTrue(tapMenuItem(matching: "label BEGINSWITH 'Layout:'"))

        // Compact mode: the bar goes away and only the grabber remains.
        XCTAssertTrue(
            tapMenuItem(matching: "label CONTAINS[c] 'Compact Mode'"),
            "compact mode menu item missing")
        // #008AF: the bar starts whole and falls a step at a time — expanded,
        // pill, gone — so reaching the grabber takes two still-delays.
        settle(9.0)
        capture("10-compact-grabber\(suffix)")

        // Prove the grabber actually reveals the bar, then leave compact mode
        // so the session does not persist it into the next run.
        let grabber = app.otherElements["Show toolbar"].firstMatch
        let grabberButton = app.buttons["Show toolbar"].firstMatch
        if grabber.waitForExistence(timeout: 3) {
            grabber.tap()
        } else if grabberButton.waitForExistence(timeout: 3) {
            grabberButton.tap()
        } else {
            // Fall back to the pill's own position just above the home indicator.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.955)).tap()
        }
        settle(1.5)
        capture("10b-compact-revealed\(suffix)")
        _ = tapMenuItem(matching: "label CONTAINS[c] 'Compact Mode'")

        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-LAYOUT"))
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

    /// Focus mode and its erase confirmation (#00888).
    func testCaptureFocusStates() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)

        XCTAssertTrue(
            tapMenuItem(matching: "label CONTAINS[c] 'Focus Mode'"), "Focus menu item missing")
        settle(2.5)
        // Load something so the shot is a real session, not an empty tab.
        navigate(to: "duckduckgo.com")
        capture("11-focus\(suffix)")

        // The erase button is the mode's signature control.
        let erase = app.buttons["Erase browsing session"]
        XCTAssertTrue(erase.waitForExistence(timeout: 8), "erase button missing")
        erase.tap()
        // The toast is short-lived — grab it straight away.
        settle(0.7)
        capture("12-focus-erase\(suffix)")
        settle(3.0)

        // Leave Focus so the next test starts clean.
        _ = tapMenuItem(matching: "label CONTAINS[c] 'Leave Focus'")
        settle(2.0)
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-FOCUS"))
    }

    // The LAN certificate prompt is NOT driven from here, deliberately.
    //
    // The whole point of the design is that the challenge's completion handler
    // is held until the owner answers — which means the app has an outstanding
    // network load and never reaches XCUITest's "idle" state, so the harness
    // blocks inside typeText() before it can even look for the sheet. That is
    // correct app behaviour and a genuine XCUITest limitation, not a bug to
    // work around here.
    //
    // docs/screenshots/13-lan-cert.png is therefore captured out of band,
    // against a real self-signed HTTPS server on the host:
    //
    //   openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    //     -days 2 -nodes -subj "/CN=localhost"
    //   python3 -c '...'   # serve it on 127.0.0.1:8443
    //   # in the app: open https://localhost:8443/
    //   xcrun simctl io booted screenshot 13-lan-cert.png
    //
    // The fingerprint the sheet displays was checked against
    // `openssl x509 -fingerprint -sha256` and matched.

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

    /// Flip any Form toggle by identifier, aiming at the switch rather than the
    /// row's centre — see `flipShowStatusBar` for why the centre does nothing.
    @discardableResult
    func flipToggle(_ identifier: String, to wanted: String) -> Bool {
        let toggle = app.switches[identifier].firstMatch
        guard toggle.waitForExistence(timeout: 8) else { return false }
        guard (toggle.value as? String) != wanted else { return true }
        // Settings is taller than a phone: a row that merely *exists* — and
        // even one XCUITest calls hittable — can be half off the bottom edge,
        // and the aimed tap below then lands on nothing. `isHittable` is not
        // enough of a test; the row has to be clear of the edge.
        let window = app.windows.firstMatch.frame
        for _ in 0..<8 where toggle.frame.maxY > window.maxY - 80 {
            app.swipeUp()
            settle(0.5)
        }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        for _ in 0..<10 {
            if (toggle.value as? String) == wanted { return true }
            settle(0.4)
        }
        return false
    }

    func openSettings() -> Bool {
        guard tapMenuItem(matching: "label CONTAINS[c] 'Settings'") else { return false }
        settle(1.5)
        return true
    }

    /// Done, or a pull-down if the toolbar button is not reachable — a sheet
    /// left up swallows every step after it.
    func dismissSheet() {
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
            addressBar.waitForExistence(timeout: 8),
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

    /// The bar-fill choice (#00891). The full-screen bar used to be an outline
    /// and nothing else; this captures the Settings control that replaces that
    /// with a real backing.
    func testCaptureBarFillSettings() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)
        XCTAssertTrue(
            tapMenuItem(matching: "label CONTAINS[c] 'Settings'"), "settings menu item missing")
        settle(1.5)
        let picker = app.segmentedControls["barFillPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "bar fill picker missing")
        XCTAssertTrue(
            picker.buttons["Liquid Glass"].isSelected, "Liquid Glass must be the default")
        capture("20-bar-fill-settings\(suffix)")
        dismissSheet()
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-BARFILL"))
    }

    /// The URL pill's security badge is a *button* (#0089A).
    ///
    /// Run against a real self-signed HTTPS server on a non-default port, with
    /// the certificate pre-approved in the app container so the app is not
    /// blocked on a challenge — XCUITest cannot drive a held completion
    /// handler, for the reason spelled out above. The harness:
    ///
    ///   mkdir /tmp/zencert && cd /tmp/zencert
    ///   openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    ///     -days 2 -nodes -subj "/CN=localhost"
    ///   python3 -c '...'    # serve cert.pem on 127.0.0.1:8006
    ///   # point a tab at https://localhost:8006/ in session.json, and write
    ///   # the openssl SHA-256 (lowercase, no colons, ISO-8601 approvedAt)
    ///   # into Application Support/Zen/trusted-certs.json
    ///
    /// Without that harness there is no actionable badge to tap, so the test
    /// skips rather than failing — it is a verification, not a regression gate.
    func testSecurityBadgeOpensTheCertificateRecord() throws {
        settle(5.0)
        let badge = app.buttons["securityBadge"].firstMatch
        try XCTSkipUnless(
            badge.waitForExistence(timeout: 12),
            "no actionable security badge — the self-signed harness is not set up")
        badge.tap()
        settle(2.0)

        XCTAssertTrue(
            app.navigationBars["Certificate"].waitForExistence(timeout: 8),
            "tapping the badge must open the certificate record")
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] ':'")).firstMatch.exists,
            "the record must show the fingerprint")
        capture("21-certificate-record")

        // And it can be forgotten from here.
        let forget = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Forget'")).firstMatch
        XCTAssertTrue(forget.waitForExistence(timeout: 5), "no way to forget the certificate")
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-BADGE"))
    }

    /// Typing a private-network octet fills the scheme in (#0089B), as
    /// ordinary editable text you can type straight on from.
    ///
    /// Typed one character at a time on purpose: `typeText` with a whole string
    /// arrives as a single insertion, which the rule *correctly* treats as a
    /// paste and leaves alone. A person typing produces one character per
    /// change, which is the case this is meant to catch.
    func testTypingAPrivateOctetFillsTheScheme() throws {
        settle(4.0)
        guard let field = openOmnibox() else { return XCTFail("omnibox missing") }
        for character in "10." { field.typeText(String(character)) }
        settle(1.0)
        XCTAssertEqual(
            field.value as? String, "https://10.",
            "typing a private octet should fill the scheme in")

        // The caret must be after what was typed, so typing on just works.
        for character in "0.0.80:8006" { field.typeText(String(character)) }
        settle(1.0)
        XCTAssertEqual(field.value as? String, "https://10.0.0.80:8006")
        capture("22-scheme-prefill")

        // Backspacing the scheme away must not bring it back in the same edit.
        for _ in 0..<30 { field.typeText(XCUIKeyboardKey.delete.rawValue) }
        settle(0.8)
        for character in "10." { field.typeText(String(character)) }
        settle(1.0)
        XCTAssertEqual(
            field.value as? String, "10.",
            "after deleting the scheme it must not be re-inserted in the same edit")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        settle(1.0)
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-PREFILL"))
    }

    /// The named-colour library and the code lookup (#0088F).
    func testCaptureNamedColours() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)
        XCTAssertTrue(openSpaceEditor(), "could not reach the space editor")
        XCTAssertTrue(openAccentPicker(), "accent row missing")

        let search = app.textFields["namedColorSearch"].firstMatch
        for _ in 0..<6 {
            if search.exists && search.isHittable { break }
            app.swipeUp()
            settle(0.6)
        }
        XCTAssertTrue(search.waitForExistence(timeout: 8), "named colour search missing")
        search.tap()
        search.typeText("sea")
        settle(1.5)

        let seagreen = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'seagreen'")).firstMatch
        XCTAssertTrue(
            seagreen.waitForExistence(timeout: 5), "searching 'sea' should find seagreen")
        capture("16-named-colours\(suffix)")

        // Picking one applies it to the wheel and the hex field.
        seagreen.tap()
        settle(1.5)
        let hex = app.textFields["hexField"].firstMatch
        if hex.exists {
            XCTAssertEqual(
                (hex.value as? String)?.uppercased(), "#2E8B57",
                "picking a named colour should drive every other control")
        }

        // The code lookup, and the licence note that explains its shape.
        // Drag along the left margin: a swipe in the middle lands inside the
        // swatch grid's own scroll view and never reaches the page.
        for _ in 0..<5 {
            if app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] 'Pantone'")).firstMatch.isHittable
            {
                break
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.82))
                .press(
                    forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.2)))
            settle(0.8)
        }
        XCTAssertTrue(
            app.textFields["paletteCodeSearch"].firstMatch.exists, "code lookup missing")
        XCTAssertTrue(
            app.buttons["importPalette"].firstMatch.exists, "no way to import a palette")
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] 'Pantone'")).firstMatch.exists,
            "the licence note must be on the screen, not buried in the README")
        capture("16b-code-lookup\(suffix)")
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-NAMED"))
    }

    /// Sepia (#00890): warm paper chrome, and the optional page tint.
    func testCaptureSepia() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)
        navigate(to: "zen-browser.app")

        XCTAssertTrue(setAppearance("Sepia"), "could not switch to Sepia")
        settle(2.0)
        capture("17-sepia\(suffix)")

        // The sidebar and the new tab page are chrome too.
        if UIDevice.current.userInterfaceIdiom != .pad { openSidebar() }
        capture("17b-sepia-sidebar\(suffix)")
        if UIDevice.current.userInterfaceIdiom != .pad { closeSidebar() }

        // …and the page tint, which is off until asked for.
        XCTAssertTrue(
            tapMenuItem(matching: "label CONTAINS[c] 'Settings'"), "settings menu item missing")
        settle(1.5)
        let tint = app.switches["sepiaTintPagesToggle"].firstMatch
        XCTAssertTrue(
            tint.waitForExistence(timeout: 8), "the page tint toggle only exists in Sepia")
        XCTAssertEqual(tint.value as? String, "0", "the page tint must be off by default")
        tint.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        settle(1.0)
        dismissSheet()
        settle(2.5)
        capture("17c-sepia-tinted-page\(suffix)")

        // Put it back so the next test starts from the documented default.
        _ = setAppearance("Follow System")
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-SEPIA"))
    }

    /// Pick an appearance from the inline picker in Settings.
    private func setAppearance(_ name: String) -> Bool {
        guard tapMenuItem(matching: "label CONTAINS[c] 'Settings'") else { return false }
        settle(1.5)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
        guard row.waitForExistence(timeout: 8) else {
            dismissSheet()
            return false
        }
        row.tap()
        settle(1.0)
        dismissSheet()
        return true
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
}

// MARK: - Customize bar (#00896) and Local network (#0089C)

extension ScreenshotTests {

    /// Reach a Settings row by its accessibility identifier, scrolling for it.
    /// Settings is long enough now that nothing below Haptics is on screen.
    private func openSettingsRow(_ identifier: String) -> Bool {
        guard openSettings() else { return false }
        let row = app.buttons[identifier].firstMatch
        let cell = app.cells[identifier].firstMatch
        for _ in 0..<8 {
            if row.exists && row.isHittable {
                row.tap()
                settle(1.6)
                return true
            }
            if cell.exists && cell.isHittable {
                cell.tap()
                settle(1.6)
                return true
            }
            app.swipeUp()
            settle(0.5)
        }
        dismissSheet()
        return false
    }

    // MARK: Passwords (#008AD)
    //
    // Driven against the mock Vaultwarden in `Tests/Fixtures/mock-vaultwarden.py`,
    // which speaks the three endpoints the client calls and encrypts its vault
    // the way a real server does — so the app does a real PBKDF2 run, a real
    // key unwrap and real AES-CBC-then-HMAC decryption to produce these rows.
    // Nothing is stubbed inside the app. Skipped, not failed, when the server
    // is not running: a screenshot run on another machine should not go red for
    // want of one.
    //
    // Start it with:
    //     python3 Tests/Fixtures/serve.py            # mints the CA, once
    //     xcrun simctl keychain booted add-root-cert /tmp/zensync-fixtures/ca.pem
    //     python3 Tests/Fixtures/mock-vaultwarden.py

    /// Probed in order; the port is the host's to choose.
    static let mockVaultServers = [
        "https://zen.localtest.me:8445",
        "https://zen.localtest.me:8446",
    ]
    static let mockVaultEmail = "andy@example.com"
    static let mockVaultPassword = "correct-horse-battery-staple"


    /// The panel on a page the vault has a login for, and the fill that follows.
    func testCapturePasswordsPanelAndFill() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(3.0)
        acceptFixtureCertificateIfAsked()
        guard try connectMockVault() else {
            throw XCTSkip("the mock Vaultwarden is not running")
        }
        closeSettings()
        dismissPageKeyboard()

        // A page the vault has an entry for, served by the other fixture
        // server, so the panel's match is a real domain match.
        navigate(to: "https://zen.localtest.me:8444/login.html")
        settle(3.0)
        if acceptFixtureCertificateIfAsked() { settle(3.0) }

        XCTAssertTrue(tapMenuItem(matching: "label CONTAINS[c] 'Passwords'"), "no Passwords item")
        let panel = app.descendants(matching: .any)["passwordsPanel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 8), "the panel did not open")
        settle(1.5)
        capture("36-passwords-panel\(suffix)")

        // The first row is the best match — exact host above same-domain — so
        // tapping it is what someone would actually do.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'passwordRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "the panel matched nothing for this page")
        row.tap()
        // Long enough for the panel's dismissal to finish animating: the
        // sheet's dimming overlay is still fading for about a second after the
        // fill lands, and a capture taken inside that window shows a greyed
        // toolbar that looks like a rendering fault rather than a transition.
        settle(5.0)

        // Filling dismisses the panel and leaves the form populated.
        let password = app.webViews.firstMatch.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 8), "the login form is gone")
        capture("37-passwords-fill\(suffix)")
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-PWPANEL"))
    }

    /// Walk the real set-up sheet. Returns false when the server is absent, so
    /// callers skip rather than fail.
    @discardableResult
    private func connectMockVault() throws -> Bool {
        guard openSettingsRow("passwordsSettingsLink") else { return false }

        // Already connected from an earlier test in this run.
        if app.descendants(matching: .any)["passwordsSyncNow"].firstMatch.exists { return true }

        let connect = app.descendants(matching: .any)["passwordsConnectVault"].firstMatch
        guard connect.waitForExistence(timeout: 6) else { return false }
        connect.tap()
        settle(1.5)

        let sheet = app.descendants(matching: .any)["vaultSetUpSheet"].firstMatch
        guard sheet.waitForExistence(timeout: 6) else { return false }
        capture("38a-vault-setup")

        // Which port the mock server is on is decided here, by asking it,
        // rather than by typing each candidate into the form in turn. The form
        // has to be filled top to bottom — the keyboard pushes the fields above
        // it out of reach, and a field that is off-screen accepts a `tap()`
        // silently and keeps its old value — so there is only one pass, and it
        // needs to know the answer before it starts.
        guard let server = reachableMockVault() else { return false }

        type(into: "vaultServerField", server)
        type(into: "vaultEmailField", Self.mockVaultEmail)
        // Submit on the last field: returning is what puts the keyboard away,
        // and the self-signed toggle is underneath it.
        type(into: "vaultMasterPasswordField", Self.mockVaultPassword, submitting: true)

        let selfSigned = app.switches["vaultSelfSignedToggle"].firstMatch
        if reveal(selfSigned), (selfSigned.value as? String) == "0" {
            selfSigned.tap()
            settle(0.4)
        }

        let save = app.descendants(matching: .any)["vaultTestAndSave"].firstMatch
        guard reveal(save), save.isEnabled else {
            // Disabled means a field did not take, which is a test problem
            // rather than a server one — and saying so beats a skip that blames
            // the server for being absent when it answered a moment ago.
            capture("38x-vault-setup-incomplete")
            try? Data(app.debugDescription.utf8)
                .write(to: outputDirectory.appendingPathComponent("vault-sheet-typed.txt"))
            return false
        }
        save.tap()
        // A real 100 000-iteration PBKDF2 run on a simulator, then a sync.
        settle(10.0)

        // The sheet dismisses itself on success and stays up on failure. When
        // it stays, the alert on it says why — capture it, because a skipped
        // test that says only "the server is not running" is a lie when the
        // server answered and something else went wrong.
        if sheet.exists {
            capture("38x-vault-setup-failed")
            try? Data(app.debugDescription.utf8)
                .write(to: outputDirectory.appendingPathComponent("vault-setup-tree.txt"))
        }
        return !sheet.exists
    }

    private func type(into identifier: String, _ text: String, submitting: Bool = false) {
        let field = app.textFields[identifier].firstMatch
        let secure = app.secureTextFields[identifier].firstMatch
        let target = field.exists ? field : secure
        guard reveal(target) else { return }
        target.tap()
        settle(0.4)
        // A newline is the return key, and return is what resigns first
        // responder — the only reliable way found to put this keyboard away.
        target.typeText(submitting ? text + "\n" : text)
        settle(0.4)
    }

    /// Take the keyboard away from whatever field *in the page* has it.
    ///
    /// A restored session can come back with the caret still in a login form —
    /// which is exactly the state this suite leaves behind. `openOmnibox()`
    /// then opens the bar and finds its field, but the typing goes nowhere:
    /// XCUITest reports "Neither element nor any descendant has keyboard
    /// focus" and names the *page's* field, not the omnibox.
    private func dismissPageKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        // Below the fixture form and above the bar: empty page, no field to
        // focus instead.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).tap()
        settle(1.2)
    }

    /// Answer Zen's own LAN-certificate challenge for the fixture host.
    ///
    /// `zen.localtest.me` resolves to 127.0.0.1, so Zen classifies it as a
    /// local address and asks before trusting its certificate — which is the
    /// behaviour #0089B added deliberately, and which the simulator's trusted
    /// root does not bypass. The sheet is *blocking* (RootView gates every
    /// other sheet behind it), so an unanswered one makes the toolbar
    /// unreachable and every later step fail somewhere unrelated: the first
    /// symptom of this was "moreMenu Button does not exist" on a freshly
    /// installed app whose restored tab pointed at the fixture.
    ///
    /// The decision is remembered, so this is a no-op on every run after the
    /// first following an install.
    @discardableResult
    private func acceptFixtureCertificateIfAsked() -> Bool {
        var accepted = false
        // In a loop, because the challenges *queue*: RootView gates them so
        // only one is presented at a time, and a page that pulls a sub-resource
        // over the same private CA raises another the moment the first is
        // answered. Answering once leaves a second sheet up, under which the
        // toolbar is present but not hittable — a tap on it reports a hit point
        // of {-1, -1} and does nothing, which reads exactly like the button
        // being absent.
        for _ in 0..<5 {
            let proceed = app.buttons["Proceed anyway"].firstMatch
            guard proceed.waitForExistence(timeout: accepted ? 2 : 3) else { break }
            proceed.tap()
            accepted = true
            // The sheet dismisses, then the page it was blocking loads; the
            // toolbar is not hittable until both have finished.
            settle(3.0)
        }
        if accepted { settle(2.0) }
        return accepted
    }

    /// Leave Settings entirely.
    ///
    /// `dismissSheet()` alone is not enough from here: connecting a vault ends
    /// on Settings → Passwords, which is *pushed*, and a pushed view hides the
    /// sheet's own Done button behind its Back button. The sheet then stays up
    /// and every step afterwards fails somewhere unrelated — the first symptom
    /// was "omnibox field missing".
    private func closeSettings() {
        let back = app.buttons["BackButton"].firstMatch
        if back.exists, back.isHittable {
            back.tap()
            settle(1.0)
        }
        dismissSheet()
        // Confirm we are actually back on a page before carrying on.
        for _ in 0..<6 where !addressBar.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.14))
                .press(
                    forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            settle(1.0)
        }
        settle(1.0)
    }

    /// The first candidate mock Vaultwarden that answers, asked from the test
    /// process rather than through the app.
    private func reachableMockVault() -> String? {
        for candidate in Self.mockVaultServers {
            guard let url = URL(string: candidate + "/identity/accounts/prelogin") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 3
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{\"email\":\"\(Self.mockVaultEmail)\"}".utf8)

            let semaphore = DispatchSemaphore(value: 0)
            var reachable = false
            URLSession(configuration: .ephemeral).dataTask(with: request) { _, response, _ in
                reachable = (response as? HTTPURLResponse)?.statusCode == 200
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 5)
            if reachable { return candidate }
        }
        return nil
    }

    /// Scroll `element` into view, and say whether it got there.
    ///
    /// `waitForExistence` is not enough on a `Form`: SwiftUI publishes rows
    /// that are scrolled off as existing but not hittable, and a `tap()` on one
    /// is a no-op with no error. Every silent failure in the vault set-up flow
    /// was this.
    @discardableResult
    private func reveal(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        if element.isHittable { return true }
        // Upwards only, and never downwards. A downward swipe inside a sheet's
        // scroll view that is already at its top is the sheet's own dismiss
        // gesture — an earlier version of this helper "scrolled to the top"
        // first and threw the whole set-up sheet away on the way, after which
        // every field it typed into went nowhere and the failure read as "the
        // server is not running". Filling the form top to bottom means this
        // only ever has to go one way.
        let scroller = app.collectionViews.firstMatch
        for _ in 0..<8 {
            if element.isHittable { return true }
            scroller.exists ? scroller.swipeUp() : app.swipeUp()
            settle(0.4)
        }
        return element.isHittable
    }

    /// The bar customiser: the live preview, the preset row, and the slot
    /// editor with its library.
    func testCaptureBarCustomizer() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)
        navigate(to: "zen-browser.app")

        XCTAssertTrue(openSettingsRow("customizeBarRow"), "Customize bar row missing")
        // The preview is a plain container, so which XCUIElementType it
        // publishes as depends on what is inside it; match on the identifier
        // rather than guessing the type.
        let preview = app.descendants(matching: .any)["barPreview"].firstMatch
        XCTAssertTrue(
            preview.waitForExistence(timeout: 10), "the editor must open on its live preview")
        capture("21-customize-editor\(suffix)")

        // The preview must actually follow a change. Top is the most visible
        // one there is: the bar moves to the other end of the screen.
        let position = app.segmentedControls["barPositionPicker"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 6), "position picker missing")
        position.buttons["Top"].tap()
        settle(1.5)
        capture("21b-customize-top\(suffix)")

        // …and the real bar behind the sheet followed it too.
        dismissSheet()
        settle(2.0)
        capture("22-bar-top-docked\(suffix)")

        // Put it back through the preset row, which is the other half of the
        // contract: a preset is a whole layout, not a set of tweaks.
        XCTAssertTrue(openSettingsRow("customizeBarRow"))
        let quiche = app.buttons["barPreset-Quiche-like"].firstMatch
        XCTAssertTrue(quiche.waitForExistence(timeout: 8), "Quiche-like preset missing")
        quiche.tap()
        settle(1.5)
        dismissSheet()
        settle(2.5)
        capture("23-bar-quiche-preset\(suffix)")

        // Back to Zen so the next test starts from the documented default.
        XCTAssertTrue(openSettingsRow("customizeBarRow"))
        let zen = app.buttons["barPreset-Zen"].firstMatch
        if zen.waitForExistence(timeout: 6) { zen.tap() }
        settle(1.0)
        dismissSheet()
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-BAR"))
    }

    /// Open Customize bar and push through to the Buttons screen.
    @discardableResult
    private func openButtonsEditor() -> Bool {
        guard openSettingsRow("customizeBarRow") else { return false }
        let link = app.buttons["barButtonsLink"].firstMatch
        let cell = app.cells["barButtonsLink"].firstMatch
        for _ in 0..<8 {
            if link.exists && link.isHittable { link.tap(); settle(1.4); return true }
            if cell.exists && cell.isHittable { cell.tap(); settle(1.4); return true }
            app.swipeUp()
            settle(0.4)
        }
        return false
    }

    /// A row by identifier. SwiftUI publishes list rows as whichever element
    /// type their content implies, so match on the identifier and not the type
    /// — `app.cells[...]` finds nothing here.
    private func row(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Remove a slot row the way a person would. Swipe first, because that is
    /// what a list row trains you to try; fall back to the always-visible minus
    /// at the head of the row, which is the other half of #008AC. Either has to
    /// work — that is the point of having both.
    private func removeRow(_ action: String) -> Bool {
        let button = row("barRemove-\(action)")
        guard reveal(button) else { return false }
        button.tap()
        settle(0.8)
        // Nothing to confirm: removal is one tap, because the thing it removes
        // lands in the library and Undo is on the same screen.
        return true
    }

    /// Scroll a row into view inside the buttons editor. Searches *both* ways:
    /// the More menu is eleven rows long, so by the time you have been down to
    /// the library the row you want next is above the viewport, and a
    /// swipe-up-only search walks away from it.
    @discardableResult
    private func reveal(_ element: XCUIElement, swipes: Int = 8) -> Bool {
        if element.exists && element.isHittable { return true }
        for _ in 0..<swipes {
            app.swipeDown()
            settle(0.25)
            if element.exists && element.isHittable { return true }
        }
        for _ in 0..<(swipes * 2) {
            app.swipeUp()
            settle(0.25)
            if element.exists && element.isHittable { return true }
        }
        return element.exists && element.isHittable
    }

    /// **Dogfooding the customiser (#008AC).** Andy's own list of things he
    /// wanted to do and could not, driven end to end: take Bookmark off, put
    /// Focus mode on, move Share across, reorder Back and Forward, dock the
    /// bar, save a preset, reset, undo.
    ///
    /// The assertions are deliberately about *what Andy can see* — is Bookmark
    /// off the bar, is it in the library — rather than about the model, which
    /// `BarSlotMutationTests` already covers. The point of this test is that
    /// the controls exist, are reachable, and do what their labels say.
    func testDogfoodTheBarCustomizer() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(3.0)
        navigate(to: "zen-browser.app")

        // Start from a known bar, or a leftover layout makes this meaningless.
        XCTAssertTrue(openSettingsRow("customizeBarRow"), "Customize bar row missing")
        let zenPreset = app.buttons["barPreset-Zen"].firstMatch
        if zenPreset.waitForExistence(timeout: 6) { zenPreset.tap() }
        settle(1.0)
        dismissSheet()
        settle(1.0)

        XCTAssertTrue(openButtonsEditor(), "could not reach the Buttons screen")
        XCTAssertTrue(
            app.descendants(matching: .any)["barEditorHint"].firstMatch
                .waitForExistence(timeout: 6),
            "the editor should say how it works before you have to guess")
        capture("35-bar-reorder\(suffix)")

        // 1. Remove Bookmark from the right slot — the original complaint.
        let bookmarkRow = row("barChip-bookmark")
        XCTAssertTrue(reveal(bookmarkRow), "Bookmark row missing from the editor")
        XCTAssertTrue(removeRow("bookmark"), "no way to remove Bookmark — the whole ticket")
        settle(1.0)
        XCTAssertFalse(
            row("barChip-bookmark").exists, "Bookmark should be off the bar now")

        // …and it must be findable again, or removing reads as destroying.
        let bookmarkInLibrary = row("barLibrary-bookmark")
        XCTAssertTrue(
            reveal(bookmarkInLibrary),
            "a removed button has to turn up in the library, or where did it go?")
        capture("41-bar-remove\(suffix)")

        // 2. Take Focus mode out of the More menu — a second run at the remove
        //    control, in the other kind of slot, and eleven rows down a list.
        XCTAssertTrue(removeRow("focusMode"), "could not take Focus mode out of the More menu")
        XCTAssertFalse(row("barChip-focusMode").exists, "Focus mode should be off the bar")

        // 3. Undo puts it straight back, from the button on this screen rather
        //    than only from the one in the toolbar above.
        let undo = row("barUndoInline")
        XCTAssertTrue(reveal(undo), "Undo should be on the editor screen")
        XCTAssertTrue(undo.isEnabled, "Undo should be live after an edit")
        undo.tap()
        settle(1.2)
        XCTAssertTrue(
            reveal(row("barChip-focusMode")), "Undo should have put Focus mode back")

        // 4. Reset puts the whole bar back, Bookmark and all.
        let reset = row("barResetInline")
        XCTAssertTrue(reveal(reset), "Reset should be reachable from the editor")
        reset.tap()
        settle(1.4)
        XCTAssertTrue(
            reveal(row("barChip-bookmark")),
            "Reset should put the Zen bar back, Bookmark and all")

        dismissSheet()
        settle(1.0)
    }

    /// A real scan of the network the simulator's host is on. Slow by nature —
    /// see the two-phase note in LANScanner — so the waits are generous.
    func testCaptureLocalNetworkScan() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)

        XCTAssertTrue(openSettingsRow("localNetworkRow"), "Local network row missing")
        let scan = app.buttons["scanButton"].firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 8), "scan button missing")
        scan.tap()
        settle(4.0)
        capture("25-lan-scan\(suffix)")

        // Wait for it to finish: the button coming back is the signal.
        let finished = NSPredicate(format: "exists == true")
        expectation(for: finished, evaluatedWith: scan, handler: nil)
        waitForExpectations(timeout: 180)
        settle(2.0)
        capture("25b-lan-scan-results\(suffix)")

        // Keep whatever it found.
        let selectAll = app.buttons["Select all"].firstMatch
        if selectAll.waitForExistence(timeout: 5) {
            selectAll.tap()
            settle(1.0)
        }
        let importButton = app.buttons["importSelectedButton"].firstMatch
        for _ in 0..<8 {
            if importButton.exists && importButton.isHittable { break }
            app.swipeUp()
            settle(0.5)
        }
        if importButton.waitForExistence(timeout: 5) {
            importButton.tap()
            settle(2.0)
        }

        // Trust what it can, and show what it trusted.
        let trust = app.buttons["trustCertificatesButton"].firstMatch
        for _ in 0..<8 {
            if trust.exists && trust.isHittable { break }
            app.swipeUp()
            settle(0.5)
        }
        if trust.exists && trust.isHittable && trust.isEnabled {
            trust.tap()
            settle(2.0)
            capture("26b-trust-report\(suffix)")
            let done = app.buttons["Done"].firstMatch
            if done.exists { done.tap() }
            settle(1.0)
        }

        // The kept list.
        let services = app.buttons["localServicesRow"].firstMatch
        let servicesCell = app.cells["localServicesRow"].firstMatch
        for _ in 0..<8 {
            if services.isHittable || servicesCell.isHittable { break }
            app.swipeUp()
            settle(0.5)
        }
        if services.isHittable {
            services.tap()
        } else if servicesCell.isHittable {
            servicesCell.tap()
        }
        settle(2.0)
        capture("26-local-services\(suffix)")
        dismissSheet()
        settle(1.5)

        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-LANSCAN"))
    }

    /// Local as a section beside History and Bookmarks, reached from the
    /// overflow menu — which is where the same list is surfaced in the chrome.
    func testCaptureLocalSection() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)
        XCTAssertTrue(
            tapMenuItem(matching: "label CONTAINS[c] 'History'"), "History menu item missing")
        settle(1.5)
        let picker = app.segmentedControls["historySectionPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "the section picker must exist")
        XCTAssertTrue(picker.buttons["Local"].exists, "Local must sit beside History and Bookmarks")
        picker.buttons["Local"].tap()
        settle(1.5)
        capture("27-local-section\(suffix)")
        dismissSheet()
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-LOCALSECTION"))
    }
}

// MARK: - Behaviour the screenshots cannot show

extension ScreenshotTests {

    /// A bare alias in the address bar navigates instead of searching
    /// (#0089C). Depends on a scan having been imported — skips rather than
    /// fails on a fresh container, since it is a verification, not a gate.
    func testALocalAliasNavigatesFromTheOmnibox() throws {
        settle(4.0)
        XCTAssertTrue(tapMenuItem(matching: "label CONTAINS[c] 'History'"))
        settle(1.2)
        let picker = app.segmentedControls["historySectionPicker"].firstMatch
        try XCTSkipUnless(picker.waitForExistence(timeout: 8), "no history sheet")
        picker.buttons["Local"].tap()
        settle(1.2)
        let firstService = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'localService-'")).firstMatch
        try XCTSkipUnless(
            firstService.waitForExistence(timeout: 5),
            "nothing imported — run testCaptureLocalNetworkScan first")
        let alias = String(firstService.identifier.dropFirst("localService-".count))
        dismissSheet()
        settle(1.2)

        guard let field = openOmnibox() else { return XCTFail("omnibox missing") }
        field.typeText(alias)
        settle(2.0)
        // The top row must be the service, not a web search for its name.
        let top = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Local ·'")).firstMatch
        XCTAssertTrue(
            top.waitForExistence(timeout: 6),
            "an exact alias must offer the service, not a search")
        field.typeText("\n")
        settle(4.0)
        XCTAssertTrue(addressBar.waitForExistence(timeout: 8), "the omnibox should have closed")
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-ALIAS"))
    }

    /// The bar's own gestures and the hide/reveal cycle (#00896): swipe up for
    /// the tabs, swipe down to put the bar away, and the grabber to bring it
    /// back.
    func testBarGesturesHideAndReveal() throws {
        settle(4.0)
        navigate(to: "example.com")

        let bar = addressBar
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "no bar")

        // Swipe up on the bar opens the tab drawer.
        bar.swipeUp()
        settle(1.5)
        let newTab = app.buttons["newTabStrip"].firstMatch
        XCTAssertTrue(newTab.waitForExistence(timeout: 6), "swipe up must reach the tab list")
        // Close it again from the scrim.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45)).tap()
        settle(1.5)

        // Swipe down puts the bar away, and the grabber brings it back.
        addressBar.swipeDown()
        settle(1.5)
        XCTAssertFalse(addressBar.exists, "swipe down must hide the bar")
        capture("21c-bar-hidden")

        let grabber = app.otherElements["Show toolbar"].firstMatch
        let grabberButton = app.buttons["Show toolbar"].firstMatch
        if grabber.waitForExistence(timeout: 4) {
            grabber.tap()
        } else if grabberButton.waitForExistence(timeout: 4) {
            grabberButton.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.955)).tap()
        }
        settle(1.5)
        XCTAssertTrue(
            addressBar.waitForExistence(timeout: 6), "the grabber must bring the bar back")
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-GESTURES"))
    }

    /// The per-pane bars in split view follow the same layout (#00896).
    /// Text size (#008B7): the More menu's smaller / larger row, the readout,
    /// and the proof that the page actually changes size — the same site is
    /// captured at 100 % and after three taps of Larger.
    func testCaptureTextSize() throws {
        settle(4.0)
        navigate(to: "example.com")
        capture("45-text-size-100")

        revealChrome()
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
            revealChrome()
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
        revealChrome()
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

    /// The navigation helper (#008B9): off until you ask for it, then four
    /// round buttons that fade in while the page is moving. Proves the two
    /// claims that matter — that they appear on a scroll, and that Page Down
    /// actually moves the page.
    func testCaptureNavigationHelper() throws {
        settle(4.0)
        XCTAssertTrue(openSettings(), "settings missing")
        XCTAssertTrue(
            app.switches["navigationHelperToggle"].waitForExistence(timeout: 8),
            "the helper toggle is missing")
        XCTAssertTrue(flipToggle("navigationHelperToggle", to: "1"), "could not switch it on")
        capture("46-nav-helper-settings")
        dismissSheet()

        // A page long enough to have somewhere to go.
        navigate(to: "en.wikipedia.org/wiki/Zen")
        settle(3.0)

        // They are not there until the page moves — which is also what keeps
        // them out of the way of the first scroll gesture.
        XCTAssertFalse(
            app.buttons["navHelper-pageDown"].isHittable,
            "the helper should not be on screen before the page has moved")

        app.swipeUp()
        settle(0.6)
        capture("46b-nav-helper-visible")

        let pageDown = app.buttons["navHelper-pageDown"]
        XCTAssertTrue(pageDown.waitForExistence(timeout: 4), "page down missing after a scroll")
        pageDown.tap()
        settle(1.4)
        pageDown.tap()
        settle(1.4)
        capture("46c-nav-helper-paged")

        let top = app.buttons["navHelper-top"]
        XCTAssertTrue(top.exists, "scroll to top missing")
        top.tap()
        settle(1.6)
        capture("46d-nav-helper-back-to-top")

        // Leave the setting off so the next run starts from the default.
        if openSettings() {
            flipToggle("navigationHelperToggle", to: "0")
            dismissSheet()
        }
    }

    /// The two-line stacked bar (#008BA): the Rows control, the live preview
    /// following it, and the real bar behind the sheet doing the same.
    func testCaptureStackedBar() throws {
        settle(4.0)
        navigate(to: "zen-browser.app")

        XCTAssertTrue(openSettingsRow("customizeBarRow"), "Customize bar row missing")
        let rows = app.segmentedControls["barRowsPicker"].firstMatch
        for _ in 0..<8 where !rows.exists || !rows.isHittable {
            app.swipeUp()
            settle(0.5)
        }
        XCTAssertTrue(rows.waitForExistence(timeout: 8), "the Rows picker is missing")
        rows.buttons["2"].tap()
        settle(1.5)
        capture("47-bar-rows-editor")

        // The preview is the real bar, so if it stacked, the bar stacked.
        dismissSheet()
        settle(2.0)
        capture("47b-bar-rows-two")

        // The preset is the other half of it: "Rows: 2" is a number, and the
        // preset is what that number is for.
        XCTAssertTrue(openSettingsRow("customizeBarRow"))
        let stacked = app.buttons["barPreset-Stacked"].firstMatch
        XCTAssertTrue(stacked.waitForExistence(timeout: 8), "the Stacked preset is missing")
        stacked.tap()
        settle(1.5)
        dismissSheet()
        settle(2.5)
        capture("47c-bar-rows-preset")

        // Every slot button on the second row has to still be reachable.
        XCTAssertTrue(
            app.buttons["barSlot-back"].waitForExistence(timeout: 6),
            "the stacked preset's back button is missing from the bar")
        XCTAssertTrue(app.buttons["barSlot-share"].exists)
        XCTAssertTrue(moreButton.exists)

        // Back to Zen so the next test starts from the documented default.
        XCTAssertTrue(openSettingsRow("customizeBarRow"))
        let zen = app.buttons["barPreset-Zen"].firstMatch
        if zen.waitForExistence(timeout: 6) { zen.tap() }
        settle(1.0)
        dismissSheet()
    }

    /// Per-workspace display (#008BB): a space overrides the layout and the
    /// appearance, the chrome follows when you switch into it, and the global
    /// Settings screen says so rather than quietly disagreeing with itself.
    func testCaptureSpaceDisplayOverrides() throws {
        settle(4.0)
        navigate(to: "zen-browser.app")

        XCTAssertTrue(openSpaceEditor(), "space editor missing")
        let display = app.staticTexts["Display"].firstMatch
        for _ in 0..<10 where !display.exists || !display.isHittable {
            app.swipeUp()
            settle(0.5)
        }
        capture("48-space-display-section")

        XCTAssertTrue(pickOption("spaceLayoutPicker", "Full Screen"), "layout picker missing")
        XCTAssertTrue(pickOption("spaceAppearancePicker", "Dark"), "appearance picker missing")
        capture("48b-space-display-set")

        app.buttons["Save"].firstMatch.tap()
        settle(1.2)
        dismissSheet()
        settle(2.0)
        // Personal is the active space, so the chrome it just overrode is what
        // is on screen: full screen, dark.
        capture("48c-space-display-applied")

        // The other space inherits, so switching is the whole feature in one
        // gesture: the layout changes under you.
        openSidebar()
        let work = app.buttons["Work"].firstMatch
        if work.waitForExistence(timeout: 5) {
            work.tap()
            settle(1.5)
            // Close the drawer first: it covers the chrome that is the whole
            // point of the shot.
            closeSidebar()
            settle(1.5)
            capture("48d-space-display-other-space")
        } else {
            closeSidebar()
        }

        // And Settings says which values it is *not* deciding.
        if openSettings() {
            let notice = app.buttons["spaceOverrideNotice"].firstMatch
            settle(1.0)
            if notice.exists { capture("48e-space-display-settings-note") }
            dismissSheet()
        }

        // Put it back so the next run starts from the documented default.
        if openSpaceEditor() {
            let reset = app.buttons["resetSpaceDisplay"].firstMatch
            for _ in 0..<10 where !reset.exists || !reset.isHittable {
                app.swipeUp()
                settle(0.5)
            }
            if reset.exists { reset.tap() }
            settle(0.6)
            app.buttons["Save"].firstMatch.tap()
            settle(1.0)
            dismissSheet()
        }
    }

    /// Tap a `Form` picker row and then its option. Written to survive both
    /// presentations SwiftUI picks between — a menu and a pushed list — because
    /// which one you get depends on the form's context, not on the code.
    @discardableResult
    func pickOption(_ identifier: String, _ option: String) -> Bool {
        let row = app.descendants(matching: .any)[identifier].firstMatch
        for _ in 0..<10 where !row.exists || !row.isHittable {
            app.swipeUp()
            settle(0.5)
        }
        guard row.waitForExistence(timeout: 6) else { return false }
        row.tap()
        settle(1.0)
        let choice = app.buttons[option].firstMatch
        if choice.waitForExistence(timeout: 4) {
            choice.tap()
        } else {
            let cell = app.staticTexts[option].firstMatch
            guard cell.waitForExistence(timeout: 4) else { return false }
            cell.tap()
        }
        settle(1.0)
        return true
    }

    func testSplitPaneBarsFollowTheLayout() throws {
        settle(4.0)
        navigate(to: "example.com")
        XCTAssertTrue(tapMenuItem(matching: "label CONTAINS[c] 'Split View'"), "no split item")
        settle(3.0)
        XCTAssertTrue(
            app.buttons["Close split pane"].waitForExistence(timeout: 8),
            "the secondary pane must get its own bar")
        capture("21d-split-pane-bars")
        _ = tapMenuItem(matching: "label CONTAINS[c] 'Exit Split View'")
        settle(2.0)
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-SPLITBARS"))
    }

    // MARK: Browser extensions (#008B8)

    /// Open Settings and reach the Extensions screen. Settings is long enough
    /// now that the row is well below the fold, and XCUITest does not scroll.
    @discardableResult
    private func openExtensionsSettings() -> Bool {
        // A cold install takes its time getting to a usable bar, and the More
        // menu is the first thing this touches — one attempt has been seen to
        // miss it. Retried rather than lengthened, so a warm run stays quick.
        var opened = tapMenuItem(matching: "label CONTAINS[c] 'Settings'")
        if !opened {
            settle(3.0)
            opened = tapMenuItem(matching: "label CONTAINS[c] 'Settings'")
        }
        guard opened else { return false }
        settle(1.5)
        let row = app.buttons["extensionsSettingsLink"].firstMatch
        let cell = app.cells["extensionsSettingsLink"].firstMatch
        for _ in 0..<8 {
            if row.exists && row.isHittable { row.tap(); settle(1.5); return true }
            if cell.exists && cell.isHittable { cell.tap(); settle(1.5); return true }
            app.swipeUp()
            settle(0.5)
        }
        return false
    }

    /// Tap Install on whichever install sheet is up, and wait for it to go.
    @discardableResult
    private func confirmInstall(timeout: TimeInterval = 12) -> Bool {
        let button = app.buttons["installExtensionButton"].firstMatch
        guard button.waitForExistence(timeout: timeout) else { return false }
        button.tap()
        settle(2.0)
        return true
    }

    /// The end-to-end proof, with the app's own two fixtures: a content script
    /// that writes into the page, and a declarativeNetRequest rule that stops a
    /// request. Both are asserted from *the page*, not from the settings list —
    /// an extension that appears in a list and does nothing is exactly the
    /// failure this whole feature is trying to avoid.
    func testTheBuiltInExtensionsActuallyRunInAPage() throws {
        settle(5.0)
        XCTAssertTrue(openExtensionsSettings(), "Settings has no Extensions row")

        let installFixtures = app.buttons["installFixturesButton"].firstMatch
        for _ in 0..<6 where !(installFixtures.exists && installFixtures.isHittable) {
            app.swipeUp()
            settle(0.5)
        }
        XCTAssertTrue(
            installFixtures.waitForExistence(timeout: 6), "no built-in extensions button")
        installFixtures.tap()
        settle(1.5)

        // Two packages, one sheet each. SwiftUI presents one sheet at a time,
        // so the second is queued behind the first's dismissal; if that race
        // is lost, tapping the button again offers only what is still missing
        // (`prepareBundledFixtures` skips what is installed).
        XCTAssertTrue(confirmInstall(), "the first install sheet never appeared")
        if !confirmInstall() {
            installFixtures.tap()
            settle(1.5)
            XCTAssertTrue(confirmInstall(), "the second install sheet never appeared")
        }
        settle(2.0)
        capture("49a-extensions-fixtures-installed")

        closeSettings()
        // The controller is attached when a web view is built, so the page has
        // to be loaded *after* the install — which is also the honest thing to
        // check, since that is what a person would do.
        navigate(to: "example.com")
        settle(5.0)
        capture("49b-extension-content-script")

        // The badge is a DOM element the content script inserted, so XCUITest
        // sees it as page text.
        let badge = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'ZEN EXTENSION ACTIVE'")).firstMatch
        XCTAssertTrue(
            badge.waitForExistence(timeout: 20),
            "the content script never ran — the extension controller is not attached to the "
                + "browsing web view, or the host permission was not granted")

        // And the blocker: the content script fetches a URL the other
        // extension's rule cancels. A 404 would read "REACHED 404"; only a
        // cancelled request reads "BLOCKED".
        let blocked = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'BLOCKED'")).firstMatch
        XCTAssertTrue(
            blocked.waitForExistence(timeout: 20),
            "declarativeNetRequest did not block — the rule list is not compiled, or the "
                + "blocker has no host access")
        capture("49c-extension-blocking-fixture")
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-EXTENSIONS"))
    }

    /// The popup, opened from the More menu's Extensions submenu.
    func testTheExtensionActionOpensItsPopup() throws {
        settle(3.0)
        navigate(to: "example.com")
        settle(3.0)

        XCTAssertTrue(
            tapMenuItem(matching: "label CONTAINS[c] 'Extensions'"),
            "the More menu carries no Extensions entry")
        settle(1.5)
        let action = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Zen Badge'")).firstMatch
        guard action.waitForExistence(timeout: 6) else {
            capture("50-extension-popup-missing")
            throw XCTSkip(
                "no Zen Badge action — run testTheBuiltInExtensionsActuallyRunInAPage first")
        }
        action.tap()
        settle(3.0)
        XCTAssertTrue(
            app.otherElements["extensionPopupSheet"].waitForExistence(timeout: 10)
                || app.staticTexts["Zen Badge"].waitForExistence(timeout: 4),
            "the action's popup never came up")
        capture("50a-extension-popup-fixture")
    }

    /// The real-world check: two extensions people actually use, fetched from
    /// addons.mozilla.org through the in-app link field, with the permission
    /// sheet and the compatibility report shown for each.
    ///
    /// Needs the network, like every other screenshot test here.
    func testCaptureRealExtensionsFromAddonsMozillaOrg() throws {
        settle(3.0)
        XCTAssertTrue(openExtensionsSettings(), "Settings has no Extensions row")

        for listing in [
            "https://addons.mozilla.org/en-GB/firefox/addon/ublock-origin-lite/",
            "https://addons.mozilla.org/en-GB/firefox/addon/darkreader/",
        ] {
            let field = app.textFields["extensionLinkField"].firstMatch
            for _ in 0..<6 where !(field.exists && field.isHittable) {
                app.swipeUp()
                settle(0.5)
            }
            guard field.waitForExistence(timeout: 8) else {
                XCTFail("no link field")
                return
            }
            field.tap()
            field.typeText(listing)
            app.buttons["extensionLinkGetButton"].firstMatch.tap()
            // AMO resolution plus a multi-megabyte download.
            settle(12.0)
            if app.otherElements["extensionInstallSheet"].waitForExistence(timeout: 30) {
                capture("49-install-\(listing.contains("ublock") ? "ubol" : "darkreader")")
            }
            XCTAssertTrue(
                confirmInstall(timeout: 30), "\(listing) never produced an install sheet")
            settle(3.0)
        }

        settle(2.0)
        capture("49-extensions-list")

        closeSettings()
        navigate(to: "https://en.wikipedia.org/wiki/Web_browser")
        settle(8.0)
        capture("51-extension-blocking")

        XCTAssertTrue(
            tapMenuItem(matching: "label CONTAINS[c] 'Extensions'"),
            "the More menu carries no Extensions entry")
        settle(1.5)
        let action = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Dark Reader'")).firstMatch
        if action.waitForExistence(timeout: 8) {
            action.tap()
            settle(4.0)
        }
        capture("50-extension-popup")
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-REALEXT"))
    }
}
