//  LoginFormFillTests.swift
//  The fill heuristics, run as JavaScript against real HTML (#008AD).
//
//  These do not test a Swift reimplementation of the heuristics — they load
//  `Sources/Passwords/LoginFormFill.swift`'s actual scripts into a real
//  `WKWebView` and run them against the fixtures in `Tests/Fixtures/forms`.
//  Anything less would be testing a model of the code rather than the code:
//  the interesting failures here are all DOM behaviour (what
//  `getComputedStyle` says about a honeypot, whether a controlled input keeps
//  a value it was given without an event), and none of them reproduce outside
//  a browser engine.
//
//  Each fixture is a named case the heuristics are known to get wrong if
//  written naively; the comment at the top of each file says which.

import WebKit
import XCTest

@testable import Zen

@MainActor
final class LoginFormFillTests: XCTestCase {

    // MARK: Detection

    func testDetectsAnOrdinaryLoginForm() async throws {
        let detection = try await detect(in: "simple-login")
        XCTAssertTrue(detection.hasLoginForm)
        XCTAssertEqual(detection.hasUsernameField, true)
        XCTAssertEqual(detection.passwordCount, 1)
        XCTAssertEqual(detection.isLikelyRegistration, false)
    }

    func testDetectsNoFormOnAnOrdinaryPage() async throws {
        let detection = try await detect(in: "no-form")
        XCTAssertFalse(detection.hasLoginForm)
    }

    /// Two password fields is a sign-up. Getting this wrong means offering to
    /// save a password the site has not accepted yet.
    func testTwoPasswordFieldsReadAsRegistration() async throws {
        let detection = try await detect(in: "registration")
        XCTAssertTrue(detection.hasLoginForm)
        XCTAssertEqual(detection.passwordCount, 2)
        XCTAssertEqual(detection.isLikelyRegistration, true)
    }

    /// The second page of a two-step sign-in has no username field at all, and
    /// must still be fillable.
    func testTwoStepSignInHasNoUsernameField() async throws {
        let detection = try await detect(in: "two-step")
        XCTAssertTrue(detection.hasLoginForm)
        XCTAssertEqual(detection.hasUsernameField, false)
    }

    // MARK: Filling

    func testFillsAnOrdinaryLoginForm() async throws {
        let view = try await load("simple-login")
        let result = try await fill(view, username: "andy@example.com", password: "hunter2")
        XCTAssertTrue(result.filled)
        XCTAssertEqual(result.filledUsername, true)
        try await assertValue(view, "#u", equals: "andy@example.com")
        try await assertValue(view, "#p", equals: "hunter2")
    }

    /// No `autocomplete` anywhere — the username has to be found by scoring
    /// `name`/`id`/`placeholder`, which is most of the real web.
    func testFillsAFormWithNoAutocompleteAttributes() async throws {
        let view = try await load("no-autocomplete")
        let result = try await fill(view, username: "andy", password: "hunter2")
        XCTAssertTrue(result.filled)
        XCTAssertEqual(result.filledUsername, true)
        try await assertValue(view, "[name=user_id]", equals: "andy")
        try await assertValue(view, "[name=pass]", equals: "hunter2")
    }

    /// The classic heuristic failure: a site-wide search box above the form.
    func testDoesNotFillASearchBoxOutsideTheForm() async throws {
        let view = try await load("search-and-login")
        let result = try await fill(view, username: "andy", password: "hunter2")
        XCTAssertTrue(result.filled)
        try await assertValue(view, "#acct", equals: "andy")
        try await assertValue(view, "#pw", equals: "hunter2")
        try await assertValue(view, "#q", equals: "")
    }

    /// Nastier: the only candidate *inside* the form is a search box. Filling
    /// only the password is the right answer — a wrong username is worse than
    /// no username, because it submits.
    func testDeclinesToGuessWhenTheOnlyCandidateIsASearchBox() async throws {
        let view = try await load("search-only-in-form")
        let result = try await fill(view, username: "andy", password: "hunter2")
        XCTAssertTrue(result.filled)
        XCTAssertEqual(result.filledUsername, false, "a search box was filled as a username")
        try await assertValue(view, "[name=search_query]", equals: "")
        try await assertValue(view, "[name=password]", equals: "hunter2")
    }

    /// Fill the first password of a sign-up form, never the confirmation.
    func testFillsOnlyTheFirstPasswordOnARegistrationForm() async throws {
        let view = try await load("registration")
        let result = try await fill(view, username: "andy@example.com", password: "hunter2")
        XCTAssertTrue(result.filled)
        XCTAssertEqual(result.passwordCount, 2)
        try await assertValue(view, "[name=password]", equals: "hunter2")
        try await assertValue(view, "[name=password_confirm]", equals: "")
    }

    func testFillsThePasswordOnlyOnATwoStepForm() async throws {
        let view = try await load("two-step")
        let result = try await fill(view, username: "andy@example.com", password: "hunter2")
        XCTAssertTrue(result.filled)
        XCTAssertEqual(result.filledUsername, false)
        try await assertValue(view, "[name=password]", equals: "hunter2")
    }

    /// Zero-sized and `display:none` fields are decoys; the visible pair is the
    /// one to fill.
    func testSkipsHiddenAndZeroSizedDecoys() async throws {
        let view = try await load("hidden-honeypot")
        let result = try await fill(view, username: "andy@example.com", password: "hunter2")
        XCTAssertTrue(result.filled)
        try await assertValue(view, "#real-user", equals: "andy@example.com")
        try await assertValue(view, "#real-pw", equals: "hunter2")
        try await assertValue(view, "[name=username]", equals: "")
        try await assertValue(view, "[name=pw_decoy]", equals: "")
    }

    /// The reason `setValue` goes through the prototype's setter and dispatches
    /// events: a controlled input reverts anything else, and the field would
    /// look filled while submitting empty.
    func testAControlledInputKeepsTheFilledValue() async throws {
        let view = try await load("controlled-input")
        let result = try await fill(view, username: "andy", password: "hunter2")
        XCTAssertTrue(result.filled)
        // Let the fixture's microtask revert anything that arrived without an
        // input event. If `setValue` were a plain assignment, this is where the
        // values would go back to empty. Slept on this side rather than in the
        // page: `evaluateJavaScript` does not await a promise, so handing it
        // one would return immediately and prove nothing.
        try await Task.sleep(for: .milliseconds(100))
        try await assertValue(view, "#u", equals: "andy")
        try await assertValue(view, "#p", equals: "hunter2")
        let model = try await view.evaluateJavaScript("window.__model.p") as? String
        XCTAssertEqual(model, "hunter2", "the page's own model never saw the fill")
    }

    func testFillingAPageWithNoFormReportsWhyRatherThanThrowing() async throws {
        let view = try await load("no-form")
        let result = try await fill(view, username: "andy", password: "hunter2")
        XCTAssertFalse(result.filled)
        XCTAssertEqual(result.reason, "no password field")
    }

    // MARK: Escaping

    /// A password is arbitrary text and goes into a script as a literal, so the
    /// characters that end literals are the ones that matter.
    ///
    /// No newline in the sample, deliberately: `<input>` is a single-line
    /// control and the HTML spec has it strip CR and LF from its value, so a
    /// round trip through one can never return them. U+2028 is the interesting
    /// case anyway — it survives the field, it is legal raw inside JSON, and it
    /// terminates a line in JavaScript, which is the one place the two grammars
    /// disagree and the reason `jsStringLiteral` escapes it by hand.
    func testHostilePasswordsSurviveTheRoundTrip() async throws {
        let nasty = #"a'b"c\d`e</script>\#u{2028}f"#
        let view = try await load("simple-login")
        let result = try await fill(view, username: nil, password: nasty)
        XCTAssertTrue(result.filled)
        let value = try await view.evaluateJavaScript("document.querySelector('#p').value")
            as? String
        XCTAssertEqual(value, nasty)
    }

    func testJSStringLiteralEncodesNilAsNull() {
        XCTAssertEqual(LoginFormFill.jsStringLiteral(nil), "null")
        XCTAssertEqual(LoginFormFill.jsStringLiteral(""), "\"\"")
        XCTAssertEqual(LoginFormFill.jsStringLiteral("a\"b"), "\"a\\\"b\"")
        // U+2028 is legal raw in JSON and a line terminator in JavaScript —
        // the one place the two grammars disagree.
        XCTAssertTrue(LoginFormFill.jsStringLiteral("a\u{2028}b").contains("\\u2028"))
    }

    // MARK: Submitted credentials

    func testSubmittedCredentialRejectsRubbishFromThePage() {
        XCTAssertNil(SubmittedCredential(messageBody: "not a dictionary"))
        XCTAssertNil(SubmittedCredential(messageBody: ["password": ""]))
        XCTAssertNil(SubmittedCredential(messageBody: ["password": "x"]))
        XCTAssertNil(
            SubmittedCredential(messageBody: ["password": "x", "url": "not a url at all ::"]))
    }

    func testSubmittedCredentialReadsAWellFormedMessage() throws {
        let credential = try XCTUnwrap(
            SubmittedCredential(messageBody: [
                "username": "andy",
                "password": "hunter2",
                "url": "https://example.com/login",
                "title": "Example",
                "isLikelyRegistration": false,
            ]))
        XCTAssertEqual(credential.username, "andy")
        XCTAssertEqual(credential.password, "hunter2")
        XCTAssertEqual(credential.url.host, "example.com")
        XCTAssertFalse(credential.isLikelyRegistration)
    }

    /// An empty username is nil, not "": the save prompt distinguishes "no
    /// username on this form" from "the username is the empty string".
    func testAnEmptyUsernameBecomesNil() throws {
        let credential = try XCTUnwrap(
            SubmittedCredential(messageBody: [
                "username": "", "password": "x", "url": "https://example.com/",
            ]))
        XCTAssertNil(credential.username)
    }

    // MARK: Plumbing

    private func load(_ fixture: String) async throws -> WKWebView {
        let bundle = Bundle(for: Self.self)
        guard
            let url = bundle.url(
                forResource: fixture, withExtension: "html", subdirectory: "Fixtures/forms")
        else {
            throw XCTSkip("fixture \(fixture).html is not in the test bundle")
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
        // A real origin, not `about:blank`: `getComputedStyle` and layout both
        // behave, and the scripts read `window.location.href`.
        view.loadHTMLString(html, baseURL: URL(string: "https://fixture.example/login"))
        // Poll for the fixture's *own* document, not merely a complete one.
        // `document.readyState` is already "complete" on the initial empty
        // document that a fresh WKWebView shows, so waiting on it alone returns
        // instantly and every later script then runs against `about:blank` —
        // which reports no inputs, no form and no error, and looks exactly like
        // a heuristics bug.
        for _ in 0..<400 {
            let marker =
                try? await view.evaluateJavaScript(
                    "document.readyState + '|' + document.location.href") as? String
            if let marker, marker.hasPrefix("complete|"), marker.contains("fixture.example") {
                return view
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw XCTSkip("fixture \(fixture).html never finished loading")
    }

    private func detect(in fixture: String) async throws -> LoginFormDetection {
        let view = try await load(fixture)
        return try await detect(view)
    }

    private func detect(_ view: WKWebView) async throws -> LoginFormDetection {
        let json = try await view.evaluateJavaScript(LoginFormFill.detectScript) as? String
        return try JSONDecoder().decode(LoginFormDetection.self, from: Data((json ?? "").utf8))
    }

    private func fill(_ view: WKWebView, username: String?, password: String) async throws
        -> LoginFormFillResult
    {
        let script = LoginFormFill.fillScript(username: username, password: password)
        let json = try await view.evaluateJavaScript(script) as? String
        return try JSONDecoder().decode(LoginFormFillResult.self, from: Data((json ?? "").utf8))
    }

    private func assertValue(
        _ view: WKWebView, _ selector: String, equals expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let script = "document.querySelector(\(LoginFormFill.jsStringLiteral(selector))).value"
        let value = try await view.evaluateJavaScript(script) as? String
        XCTAssertEqual(value, expected, "value of \(selector)", file: file, line: line)
    }
}
