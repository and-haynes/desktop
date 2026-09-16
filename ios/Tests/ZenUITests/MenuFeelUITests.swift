import XCTest

/// Run against the local compact-mode fixture on port 8876, on a fresh phone.
/// Exercises real presentations, persisted settings, and live WKWebView paging.
final class MenuFeelUITests: XCTestCase {
    private let app = XCUIApplication()
    private var address: XCUIElement { app.buttons["Address and search"] }
    private var down: XCUIElement { app.buttons["navHelper-pageDown"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func showMenu() {
        let grabber = app.buttons["Show toolbar"]
        if !address.isHittable && grabber.exists { grabber.tap() }
        app.buttons["moreMenu"].tap()
        XCTAssertTrue(app.buttons["menuSettings"].waitForExistence(timeout: 5))
    }

    /// Also runs on iPad and with the simulator's larger-text setting.
    func testMenuDestinationsAndDismissal() throws {
        let grabber = app.buttons["Show toolbar"]
        if grabber.exists { grabber.tap() }
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        showMenu()
        XCTAssertTrue(app.buttons["menuSettings"].isHittable)
        capture("menu-destinations")
        app.buttons["closeBrowserMenu"].tap()
        XCTAssertTrue(address.isHittable)
        showMenu()
        app.buttons["menuAction-share"].tap()
        XCTAssertTrue(
            app.otherElements["ActivityListView"].waitForExistence(timeout: 5),
            "Share must open after More closes")
        capture("menu-share-handoff")
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.isHittable)
        close.tap()
        showMenu()
        let fullScreen = app.buttons["menuLayout-fullScreen"]
        for _ in 0..<5 {
            if fullScreen.exists && fullScreen.isHittable { break }
            app.scrollViews["browserMenuScroll"].swipeUp()
        }
        XCTAssertTrue(fullScreen.isHittable)
        fullScreen.tap()
        showMenu()
        let card = app.buttons["menuLayout-card"]
        for _ in 0..<5 {
            if card.exists && card.isHittable { break }
            app.scrollViews["browserMenuScroll"].swipeUp()
        }
        XCTAssertTrue(card.isHittable)
        card.tap()
        showMenu()
        app.buttons["menuSettings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    func testMenuHandoffsAndBottomPagingSurviveRelaunch() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        let field = app.textFields["omniboxField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("http://127.0.0.1:8876/compact.html\n")
        XCTAssertTrue(
            app.webViews.staticTexts["Compact mode test page"].waitForExistence(timeout: 10))

        showMenu()
        if app.buttons["menuAction-compactToggle"].label.hasPrefix("Exit") {
            app.buttons["menuAction-compactToggle"].tap()
            showMenu()
        }
        capture("menu-phone")
        let readout = app.buttons["textSizeReadout"]
        let initialSize = readout.label
        app.buttons["textSizeLarger"].tap()
        XCTAssertNotEqual(readout.label, initialSize)
        app.buttons["textSizeLarger"].tap()
        XCTAssertTrue(
            app.buttons["menuSettings"].isHittable, "Repeated zoom changes keep the menu open")
        readout.tap()
        XCTAssertEqual(readout.label, initialSize)
        app.buttons["menuSettings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        let enabled = app.switches["navigationHelperToggle"]
        for _ in 0..<8 {
            if enabled.exists && enabled.frame.maxY < app.frame.height - 180 { break }
            app.swipeUp()
        }
        XCTAssertTrue(enabled.isHittable)
        if enabled.value as? String == "0" {
            enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(enabled.value as? String, "1")
        let placement = app.segmentedControls["navigationHelperPlacementPicker"]
        XCTAssertTrue(placement.waitForExistence(timeout: 5))
        placement.buttons["Bottom"].tap()
        XCTAssertFalse(app.segmentedControls["navigationHelperSidePicker"].exists)
        capture("navigation-bottom-setting")
        app.buttons["Done"].tap()

        app.webViews.firstMatch.swipeUp()
        XCTAssertTrue(down.waitForExistence(timeout: 4))
        let frames = ["top", "pageUp", "pageDown", "bottom"].map {
            app.buttons["navHelper-\($0)"].frame
        }
        for (index, frame) in frames.enumerated() {
            XCTAssertGreaterThanOrEqual(frame.width, 44)
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 1)
            if index > 0 { XCTAssertGreaterThan(frame.minX, frames[index - 1].minX) }
        }
        XCTAssertLessThan(frames[0].maxY, address.frame.minY, "The helper must clear the toolbar")
        capture("navigation-bottom-portrait")

        app.webViews.firstMatch.swipeUp()
        app.buttons["navHelper-bottom"].tap()
        let end = app.webViews.staticTexts[
            "Reading section 20. Scroll this page to dismiss the toolbar."]
        XCTAssertTrue(end.isHittable, "Bottom reaches the end of the document")
        app.buttons["navHelper-top"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Compact mode test page"].isHittable)
        down.tap()
        app.buttons["navHelper-pageUp"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Compact mode test page"].isHittable)

        // Long press uses the same panel and must not also open the address editor.
        address.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["menuSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["omniboxField"].exists)
        app.buttons["closeBrowserMenu"].tap()
        XCTAssertTrue(address.isHittable)

        app.terminate()
        app.launch()
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        app.webViews.firstMatch.swipeUp()
        XCTAssertTrue(down.waitForExistence(timeout: 4))
        XCTAssertEqual(down.frame.midY, app.buttons["navHelper-top"].frame.midY, accuracy: 1)
        XCUIDevice.shared.orientation = .landscapeLeft
        app.webViews.firstMatch.swipeUp()
        XCTAssertTrue(down.waitForExistence(timeout: 4))
        XCTAssertLessThan(down.frame.maxY, address.frame.minY)
        capture("navigation-bottom-landscape")
        XCUIDevice.shared.orientation = .portrait

        showMenu()
        app.buttons["menuAction-compactToggle"].tap()
        app.webViews.firstMatch.swipeUp()
        let grabber = app.buttons["Show toolbar"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        XCTAssertTrue(down.isHittable)
        XCTAssertLessThan(down.frame.maxY, grabber.frame.minY)
        capture("navigation-bottom-compact")
        grabber.tap()
        showMenu()
        app.buttons["menuAction-compactToggle"].tap()
    }
}
