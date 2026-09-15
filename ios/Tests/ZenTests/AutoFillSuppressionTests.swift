//  AutoFillSuppressionTests.swift
//  The things that switch iOS Password AutoFill off, asserted as absent
//  (#008AB).
//
//  On iOS a third-party browser cannot ship a password manager that other apps
//  plug into; what it gets is system Password AutoFill, which puts a key in the
//  bar above the keyboard when a `WKWebView` field is one iOS can fill. That
//  bar is not ours, and every known way of losing it is something the *app*
//  does:
//
//   - overriding `inputAccessoryView` to put a custom toolbar there,
//   - emptying `inputAssistantItem`'s bar button groups,
//   - injecting a user script that renames or rewrites login fields,
//   - adding a script message handler that steals focus.
//
//  None of those have an error to notice: the key just is not there. So rather
//  than trust a comment, this pins the absence. The end-to-end proof that the
//  key really appears is `ScreenshotTests.testPasswordAutoFillIsOfferedInTheWebView`,
//  which needs a simulator and a fixture server; these run anywhere in
//  milliseconds and are what a regression trips first.

import ObjectiveC
import WebKit
import XCTest

@testable import Zen

@MainActor
final class AutoFillSuppressionTests: XCTestCase {

    private func space() -> Space {
        Space(name: "AutoFill", icon: "key.fill", isSymbol: true)
    }

    /// Overriding this is the classic way an embedded browser replaces the
    /// form bar with its own — and the classic way it loses the AutoFill key.
    /// Compared by implementation pointer: if `ZenWebView` ever declares one,
    /// the pointers differ and this fails.
    func testTheWebViewDoesNotOverrideTheInputAccessoryView() {
        let selector = #selector(getter: UIResponder.inputAccessoryView)
        XCTAssertEqual(
            class_getMethodImplementation(ZenWebView.self, selector),
            class_getMethodImplementation(WKWebView.self, selector),
            "ZenWebView overrides inputAccessoryView — that replaces the bar "
                + "iOS puts the Password AutoFill key in")
    }

    /// The other half of the same story: emptying the assistant item's button
    /// groups removes the bar's contents without replacing the bar.
    func testTheWebViewDoesNotOverrideTheInputAssistantItem() {
        let selector = #selector(getter: UIResponder.inputAssistantItem)
        XCTAssertEqual(
            class_getMethodImplementation(ZenWebView.self, selector),
            class_getMethodImplementation(WKWebView.self, selector),
            "ZenWebView overrides inputAssistantItem — emptying its bar button "
                + "groups is what takes the AutoFill key away")
    }

    /// A user script that rewrites a login form — renaming fields, cloning
    /// inputs, re-parenting them — stops iOS recognising it. Zen's only page
    /// script observes media playback and runs in the isolated
    /// `.defaultClient` world; this guards that nothing injected ever
    /// reaches for a form, an input or a password field.
    func testBrowsingConfigurationScriptsLeaveFormsAlone() {
        let configuration = WebEngine.configuration(for: space(), desktop: false)
        assertScriptsLeaveFormsAlone(configuration)
    }

    /// Desktop mode takes a different branch through `configuration(for:)`;
    /// it must not be the one that quietly grows a form-touching script.
    func testDesktopConfigurationScriptsLeaveFormsAloneToo() {
        let configuration = WebEngine.configuration(for: space(), desktop: true)
        assertScriptsLeaveFormsAlone(configuration)
    }

    private func assertScriptsLeaveFormsAlone(
        _ configuration: WKWebViewConfiguration, file: StaticString = #filePath, line: UInt = #line
    ) {
        let forbidden = ["<form", "form", "input", "password", "autocomplete", "textarea"]
        for script in configuration.userContentController.userScripts {
            let source = script.source.lowercased()
            for word in forbidden where source.contains(word) {
                XCTFail(
                    "a user script mentions `\(word)`; scripts must leave login forms alone "
                        + "or iOS Password AutoFill goes quiet — inject in `.defaultClient` and "
                        + "observe media only", file: file, line: line)
            }
        }
    }

    /// AutoFill is origin-scoped, and iOS only offers saved logins on an origin
    /// it can name. A non-persistent store does not stop the key appearing, but
    /// a private-mode store would throw away anything the page then saved — so
    /// the browsing store has to be a real, persistent one.
    func testBrowsingUsesAPersistentDataStore() {
        let configuration = WebEngine.configuration(for: space(), desktop: false)
        XCTAssertTrue(
            configuration.websiteDataStore.isPersistent,
            "a non-persistent store loses logins between launches")
    }

    /// Two tabs in one space must share a store, or a site signed into in one
    /// looks signed out in the other — and the saved-password prompt fires
    /// again on every tab.
    func testOneSpaceGetsOneStore() {
        let space = space()
        XCTAssertTrue(WebEngine.dataStore(for: space) === WebEngine.dataStore(for: space))
    }
}
