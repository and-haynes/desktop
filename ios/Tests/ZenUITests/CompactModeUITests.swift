// Regression coverage for deliberate compact-mode reveals.
// Serve the local page before running (from ios/):
//   python3 -m http.server 8876 --bind 127.0.0.1 --directory Tests/Fixtures/compact-mode
// Run with -scheme ZenScreenshots -only-testing:ZenUITests/CompactModeUITests
// on a fresh iPhone simulator. Uses the real compact-mode delay without overrides.
import XCTest

final class CompactModeUITests: XCTestCase {
    private let app = XCUIApplication()
    private var bar: XCUIElement { app.buttons["Address and search"] }
    private var grabber: XCUIElement { app.buttons["Show toolbar"] }
    private var drawer: XCUIElement { app.buttons["newTabStrip"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitPastHideDelay() { Thread.sleep(forTimeInterval: 6) }

    func testDeliberateRevealsPersistAndGrabberDoesNotOpenTabs() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "This regression drives the iPhone drawer layout.")
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        bar.tap()
        let field = app.textFields["omniboxField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("http://127.0.0.1:8876/compact.html\n")
        XCTAssertTrue(
            app.webViews.staticTexts["Compact mode test page"].waitForExistence(timeout: 10))

        app.buttons["moreMenu"].tap()
        let compact = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Compact Mode'"))
            .firstMatch
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        compact.tap()
        // Scrolling hides the toolbar even if the menu tap counts as using it.
        app.webViews.firstMatch.swipeUp()
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        capture("compact-hidden")

        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertFalse(drawer.exists, "Pulling the grabber must only reveal the toolbar")
        capture("compact-pulled-toolbar")
        waitPastHideDelay()
        XCTAssertTrue(bar.exists && bar.isHittable, "A deliberate toolbar reveal must not time out")

        app.buttons["barSlot-sidebar"].tap()
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        waitPastHideDelay()
        XCTAssertTrue(drawer.exists && drawer.isHittable, "The selected drawer must not time out")
        capture("compact-drawer-persisted")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)))
        XCTAssertTrue(
            drawer.exists && drawer.isHittable, "Scrolling inside the drawer must not dismiss it")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertFalse(drawer.exists)
        waitPastHideDelay()
        XCTAssertTrue(
            bar.exists && bar.isHittable, "Closing the drawer must preserve the revealed toolbar")

        app.webViews.firstMatch.swipeUp()
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        XCTAssertFalse(bar.exists && bar.isHittable, "Page scrolling should dismiss the toolbar")
        grabber.tap()
        waitPastHideDelay()
        XCTAssertTrue(bar.exists && bar.isHittable, "Tapping the grabber must also persist")
        XCTAssertFalse(drawer.exists)
        capture("compact-tapped-toolbar-persisted")

        app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(
            grabber.waitForExistence(timeout: 5), "A page tap dismisses the revealed toolbar")
        grabber.tap()
        app.buttons["moreMenu"].tap()
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        compact.tap()
        // Flush the session before the next test force-terminates the app.
        XCUIDevice.shared.press(.home)
    }
}
