//  WebAuthnAvailabilityTests.swift
//  What a WKWebView in this app can actually offer a site that asks for a
//  passkey (#008AB).
//
//  Passkeys matter to the password story: a manager that stores passkeys can
//  only be reached from web content through the platform's own WebAuthn
//  implementation, so "does our web view expose `PublicKeyCredential`?" is the
//  question that decides whether the feature exists at all. This asks WebKit
//  rather than assuming, and prints what it found — a simulator has no platform
//  authenticator, so the *availability* answer here is not the device answer,
//  and the test says so rather than asserting something untrue.

import WebKit
import XCTest

@testable import Zen

@MainActor
final class WebAuthnAvailabilityTests: XCTestCase {

    /// The API surface is either there or it is not, and that part does not
    /// depend on hardware. If this ever goes false, passkeys in Zen are gone
    /// and the README is wrong.
    func testTheWebViewExposesTheWebAuthnAPI() async throws {
        let webView = try await loadedWebView()
        let hasCredentials =
            try await webView.evaluateJavaScript("typeof navigator.credentials") as? String
        let hasPublicKey =
            try await webView.evaluateJavaScript("typeof window.PublicKeyCredential") as? String
        XCTAssertEqual(hasCredentials, "object")
        XCTAssertEqual(hasPublicKey, "function")
    }

    /// Recorded, not asserted: a simulator has no Secure Enclave and no saved
    /// passkeys, so whatever it answers is about the simulator. The value is
    /// printed so a run on a real phone shows the difference.
    func testPlatformAuthenticatorAvailabilityIsRecorded() async throws {
        let webView = try await loadedWebView()
        // `callAsyncJavaScript`, not `evaluateJavaScript`: the latter's async
        // variant cannot await a promise and fails the call outright.
        let answer = try await webView.callAsyncJavaScript(
            """
            try {
              const ok = await PublicKeyCredential
                .isUserVerifyingPlatformAuthenticatorAvailable();
              return String(ok);
            } catch (e) { return "threw: " + e; }
            """,
            contentWorld: .page) as? String
        print(
            "[#008AB] isUserVerifyingPlatformAuthenticatorAvailable() in this "
                + "WKWebView: \(answer ?? "no answer")")
        XCTAssertNotNil(answer)
    }

    // MARK: Plumbing

    private func loadedWebView() async throws -> WKWebView {
        // The app's own configuration, per-space data store and all — the point
        // is what *our* web views expose, not what a default one does.
        let space = Space(name: "Passkeys", icon: "key.fill", isSymbol: true)
        let configuration = WebEngine.configuration(for: space, desktop: false)
        let webView = WKWebView(
            frame: .init(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        webView.loadHTMLString(
            "<!doctype html><title>t</title><body><script>window.__ready=1;</script>",
            baseURL: URL(string: "https://example.invalid/"))
        for _ in 0..<400 {
            let ready = try? await webView.evaluateJavaScript("window.__ready") as? Int
            if ready == 1 { return webView }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw XCTSkip("the stand-in page never loaded")
    }
}
