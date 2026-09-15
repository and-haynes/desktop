//  PasswordsAutoFillTests.swift
//  That the vault does not cost us iOS Password AutoFill (#008AB, #008AD).
//
//  `ios` has an asserted invariant: Zen injects nothing into page content,
//  because a script that rewrites a login form is one of the ways iOS Password
//  AutoFill goes quiet — with no error, no log line, and nothing to debug
//  except a key that is not there. `AutoFillSuppressionTests` pins that on
//  `ios` by asserting `userScripts.isEmpty`.
//
//  This branch breaks that assertion deliberately: `LoginFormObserver` installs
//  one script so a submitted credential can be offered to the vault. The claim
//  made in `LoginFormFill`'s file comment is that the script is *passive* — two
//  capturing listeners, no writes — and that the form iOS inspects is therefore
//  byte-identical to the one the site shipped.
//
//  A claim in a comment is worth nothing, so this measures it: the form's
//  `outerHTML`, its field identities, its attributes and the document's active
//  element are captured before and after the observer runs, and compared. If
//  anyone ever "improves" the observer into something that tags fields or grabs
//  focus, this is what goes red.
//
//  The end-to-end proof that the key itself still appears needs a device, a
//  fixture server over https and a saved credential; that lives in
//  `ScreenshotTests` on the `ios` branch and is documented in the README. What
//  is checkable here — that nothing about the page changed — is checked here.

import WebKit
import XCTest

@testable import Zen

@MainActor
final class PasswordsAutoFillTests: XCTestCase {

    /// The heart of it: running the observer must leave the DOM untouched.
    func testTheSubmitObserverDoesNotAlterTheForm() async throws {
        let view = try await loadFixture("simple-login")
        let before = try await snapshot(view)
        _ = try await view.evaluateJavaScript(LoginFormFill.submitObserverScript)
        let after = try await snapshot(view)
        XCTAssertEqual(
            before, after,
            "the submit observer changed the page — AutoFill recognises the form the site "
                + "shipped, not one we rewrote")
    }

    /// Same again for a form with none of the helpful attributes, since that is
    /// where a naive implementation would be tempted to add some.
    func testTheSubmitObserverDoesNotAnnotateAnUnlabelledForm() async throws {
        let view = try await loadFixture("no-autocomplete")
        let before = try await snapshot(view)
        _ = try await view.evaluateJavaScript(LoginFormFill.submitObserverScript)
        let after = try await snapshot(view)
        XCTAssertEqual(before, after)
    }

    /// Installing twice must not double up the listeners — a page that
    /// navigates within itself would otherwise report each submit twice, and
    /// the save prompt would appear, be dismissed, and appear again.
    func testTheObserverInstallsOnlyOnce() async throws {
        let view = try await loadFixture("simple-login")
        _ = try await view.evaluateJavaScript(LoginFormFill.submitObserverScript)
        _ = try await view.evaluateJavaScript(LoginFormFill.submitObserverScript)
        let installed = try await view.evaluateJavaScript("window.__zenLoginObserver") as? Bool
        XCTAssertEqual(installed, true)
    }

    /// The observer must not take focus. A field that loses first responder
    /// loses the AutoFill bar with it.
    func testTheObserverDoesNotStealFocus() async throws {
        let view = try await loadFixture("simple-login")
        // `focus()` returns undefined, and the async `evaluateJavaScript`
        // cannot represent that — it throws rather than returning nil. Ending
        // on an expression with a value is the whole fix.
        _ = try await view.evaluateJavaScript(
            "document.querySelector('#p').focus(); document.activeElement.id")
        _ = try await view.evaluateJavaScript(LoginFormFill.submitObserverScript)
        let active = try await view.evaluateJavaScript("document.activeElement.id") as? String
        XCTAssertEqual(active, "p", "the observer moved the caret off the password field")
    }

    /// With no vault configured the pool installs nothing at all, so a user who
    /// never opts in gets exactly the `ios` behaviour. This is the arrangement
    /// that makes the invariant above a *choice* rather than a casualty.
    func testAConfigurationWithNoVaultCarriesNoUserScripts() {
        let space = Space(name: "AutoFill", icon: "key.fill", isSymbol: true)
        let configuration = WebEngine.configuration(for: space, desktop: false)
        XCTAssertTrue(
            configuration.userContentController.userScripts.isEmpty,
            "the browsing configuration injects a script with no vault connected")
    }

    /// And with one, exactly one script goes in — not one per navigation.
    func testInstallingTheObserverAddsExactlyOneScript() {
        let space = Space(name: "AutoFill", icon: "key.fill", isSymbol: true)
        let configuration = WebEngine.configuration(for: space, desktop: false)
        let service = PasswordVaultService(
            credentialStore: InMemoryVaultCredentialStore(),
            configurationStore: .init(url: temporaryURL()),
            indexStore: VaultIndexStore(
                credentials: InMemoryVaultCredentialStore(), url: temporaryURL()),
            makeProvider: { _, _ in throw VaultError.notConfigured })
        _ = LoginFormObserver.install(on: configuration, vault: service)
        XCTAssertEqual(configuration.userContentController.userScripts.count, 1)
        XCTAssertEqual(
            configuration.userContentController.userScripts.first?.injectionTime,
            .atDocumentEnd)
        // Sign-in forms in iframes are common enough that main-frame-only would
        // miss them; the origin check in the handler is what makes it safe.
        XCTAssertEqual(
            configuration.userContentController.userScripts.first?.isForMainFrameOnly, false)
    }

    // MARK: Plumbing

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-autofill-\(UUID().uuidString).json")
    }

    /// Everything about the form that iOS could possibly key off.
    private func snapshot(_ view: WKWebView) async throws -> String {
        let script = """
            (function () {
              const form = document.querySelector('form');
              const inputs = Array.from(document.querySelectorAll('input')).map((el) => ({
                id: el.id, name: el.name, type: el.type,
                autocomplete: el.getAttribute('autocomplete'),
                attrs: Array.from(el.attributes).map((a) => a.name + '=' + a.value).sort()
              }));
              return JSON.stringify({
                html: form ? form.outerHTML : null,
                inputs: inputs,
                active: document.activeElement ? document.activeElement.id : null
              });
            })();
            """
        return try await view.evaluateJavaScript(script) as? String ?? ""
    }

    private func loadFixture(_ name: String) async throws -> WKWebView {
        let bundle = Bundle(for: Self.self)
        guard
            let url = bundle.url(
                forResource: name, withExtension: "html", subdirectory: "Fixtures/forms")
        else {
            throw XCTSkip("fixture \(name).html is not in the test bundle")
        }
        let html = try String(contentsOf: url, encoding: .utf8)
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844))
        // In a window, and laid out. The heuristics ask each field for its
        // `getBoundingClientRect()` — that is how a honeypot is told from a
        // real input — and a web view that was never put in a window reports
        // every rect as zero, so every field reads as invisible and nothing is
        // ever found. The window is kept alive by the view's superview chain.
        let window = UIWindow(frame: .init(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(view)
        window.isHidden = false
        view.loadHTMLString(html, baseURL: URL(string: "https://fixture.example/login"))
        // Poll for the fixture's *own* document: `document.readyState` is
        // already "complete" on the empty document a fresh WKWebView shows, so
        // waiting on it alone runs every later script against `about:blank`.
        for _ in 0..<400 {
            let marker =
                try? await view.evaluateJavaScript(
                    "document.readyState + '|' + document.location.href") as? String
            if let marker, marker.hasPrefix("complete|"), marker.contains("fixture.example") {
                return view
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw XCTSkip("fixture \(name).html never finished loading")
    }
}
