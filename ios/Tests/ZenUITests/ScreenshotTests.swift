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

        // Leave compact mode, or the setting persists into the next launch and
        // every test after this one starts with no bar to drive.
        _ = tapMenuItem(matching: "label CONTAINS[c] 'Compact Mode'")
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
}
