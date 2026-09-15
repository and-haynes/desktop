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
        settle(2.0)
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


    /// The accent colour tool (#0088F) and the hex entry path.
    func testCaptureColorPicker() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)

        // Settings -> the first space -> Accent.
        XCTAssertTrue(
            tapMenuItem(matching: "label CONTAINS[c] 'Settings'"), "settings menu item missing")
        settle(1.5)

        let spaceRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Personal'")).firstMatch
        XCTAssertTrue(spaceRow.waitForExistence(timeout: 8), "space row missing")
        spaceRow.tap()
        settle(1.5)

        let accent = app.buttons["accentRow"].firstMatch
        let accentCell = app.cells["accentRow"].firstMatch
        if accent.waitForExistence(timeout: 5) {
            accent.tap()
        } else if accentCell.waitForExistence(timeout: 5) {
            accentCell.tap()
        } else {
            return XCTFail("accent row missing")
        }
        settle(2.0)
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
    /// proves the Settings toggle brings it back, and puts it away again so the
    /// session does not carry the change into the next test.
    func testCaptureStatusBar() throws {
        let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
        settle(4.0)
        capture("24-status-bar-hidden\(suffix)")

        XCTAssertTrue(setShowStatusBar(true), "could not turn the status bar on")
        settle(2.0)
        capture("24b-status-bar-shown\(suffix)")

        XCTAssertTrue(setShowStatusBar(false), "the choice did not persist, or would not go back")
        settle(2.0)
        capture("24c-status-bar-hidden-again\(suffix)")
        try? Data("ok".utf8).write(to: outputDirectory.appendingPathComponent("DONE-STATUSBAR"))
    }

    /// Drive the Settings toggle to a known state. Returns false if the toggle
    /// was not where it should be, or was already the value asked for (which
    /// would mean the previous step did not take).
    private func setShowStatusBar(_ on: Bool) -> Bool {
        guard tapMenuItem(matching: "label CONTAINS[c] 'Settings'") else { return false }
        settle(1.5)
        let toggle = app.switches["showStatusBarToggle"].firstMatch
        guard toggle.waitForExistence(timeout: 8) else { return false }
        guard (toggle.value as? String) == (on ? "0" : "1") else { return false }
        // A SwiftUI Form toggle's accessibility frame is the whole row, and its
        // centre is dead space between the label and the switch — tapping there
        // does nothing. Aim at the switch.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        settle(1.2)
        let settled = (toggle.value as? String) == (on ? "1" : "0")
        dismissSheet()
        return settled
    }

    /// Done, or a pull-down if the toolbar button is not reachable — a sheet
    /// left up swallows every step after it.
    private func dismissSheet() {
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 4), done.isHittable {
            done.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
                .press(
                    forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        settle(1.5)
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
