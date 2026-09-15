//  VideoPopOutTests.swift
//  Which video gets popped out, decided against real pages (#008B0).
//
//  The finder is JavaScript that reads the DOM, so the only honest way to test
//  it is to give it a DOM. `JSContext` has no document and no layout, and a
//  hand-rolled Swift reimplementation of the ranking would be testing a copy of
//  the thing that ships. So these load fixture HTML into an off-screen
//  `WKWebView` at a phone-sized frame and evaluate the *shipped* script.
//
//  One fixture trick needs explaining. "Playing" is `!paused && !ended`, and a
//  `<video>` with no real media can never leave `paused` — so the fixtures
//  override the property with `Object.defineProperty`. That is the fixture
//  lying to the finder about one standard property, which is exactly what a
//  test double is; the finder itself is untouched.

import WebKit
import XCTest

@testable import Zen

@MainActor
final class VideoPopOutTests: XCTestCase {

    // MARK: The page

    /// A phone-sized viewport, so "visible" means what it means on a phone.
    private static let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)

    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish?()
        }
    }

    private var waiters: [LoadWaiter] = []

    /// Load a fragment of body HTML and return what the finder chose.
    private func pick(_ body: String) async throws -> VideoPopOut.Result {
        try await run(VideoPopOut.selectionScript, on: body)
    }

    /// Load a fragment of body HTML and evaluate one of the shipped scripts
    /// against it. The configuration is the app's own, so the media policy
    /// under test is the one that ships.
    private func run(_ script: String, on body: String) async throws -> VideoPopOut.Result {
        let config = WKWebViewConfiguration()
        WebEngine.applyMediaPolicy(to: config)
        let webView = WKWebView(frame: Self.viewport, configuration: config)
        let waiter = LoadWaiter()
        // Held for the duration of the test: WKWebView's delegate is weak, and
        // a deallocated one simply never calls back, which reads as a hang.
        waiters.append(waiter)
        webView.navigationDelegate = waiter

        let html = """
            <!doctype html><html><head><meta name="viewport" \
            content="width=device-width,initial-scale=1"><style>\
            body { margin: 0; } video { display: block; background: #333; }\
            </style></head><body>\(body)</body></html>
            """

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.onFinish = { continuation.resume() }
            webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.test/"))
        }
        // Layout has to have happened before getBoundingClientRect means
        // anything; didFinish is after the first layout pass for a static
        // document, but force it rather than rely on that.
        _ = try await webView.evaluateJavaScript("document.body.offsetHeight")
        let raw = try await webView.evaluateJavaScript(script)
        return VideoPopOut.Result.parse(raw)
    }

    private func video(
        id: String, width: Int, height: Int, style: String = "", playing: Bool = false
    ) -> String {
        let element = "<video id=\"\(id)\" width=\"\(width)\" height=\"\(height)\" "
            + "style=\"width:\(width)px;height:\(height)px;\(style)\"></video>"
        guard playing else { return element }
        return element + """
            <script>Object.defineProperty(document.getElementById("\(id)"), "paused", \
            { get: function () { return false; } });</script>
            """
    }

    // MARK: Nothing to pop

    func testAPageWithNoVideoFindsNothing() async throws {
        let result = try await pick("<p>Just words.</p>")
        XCTAssertEqual(result.status, .none)
        XCTAssertEqual(result.candidates, 0)
        XCTAssertEqual(result.message, "No video on this page.")
    }

    func testASingleVideoIsTheAnswer() async throws {
        let result = try await pick(video(id: "only", width: 320, height: 180))
        XCTAssertEqual(result.id, "only")
        XCTAssertEqual(result.index, 0)
        XCTAssertEqual(result.candidates, 1)
    }

    // MARK: Rule 2 — largest visible

    func testTheLargestVisibleVideoWins() async throws {
        let result = try await pick(
            video(id: "thumb", width: 80, height: 45)
                + video(id: "feature", width: 360, height: 200))
        XCTAssertEqual(result.id, "feature")
        XCTAssertEqual(result.index, 1)
    }

    /// Visible area, not intrinsic size: a big video half off the bottom of the
    /// screen is not what you are looking at.
    func testVisibleAreaBeatsRawSizeWhenOneIsOffScreen() async throws {
        let result = try await pick(
            video(id: "onscreen", width: 360, height: 300)
                + video(
                    id: "huge", width: 360, height: 900,
                    style: "position:absolute;top:-4000px;left:0;"))
        XCTAssertEqual(
            result.id, "onscreen",
            "a video parked off the top of the document should lose to one on screen")
    }

    // MARK: Rule 1 — playing beats everything

    func testAPlayingVideoWinsEvenWhenItIsTheSmallest() async throws {
        let result = try await pick(
            video(id: "tiny", width: 120, height: 68, playing: true)
                + video(id: "big", width: 360, height: 300))
        XCTAssertEqual(result.id, "tiny")
        XCTAssertTrue(result.playing)
    }

    /// Playing narrows the field; size decides inside it.
    func testAmongPlayingVideosTheLargestVisibleWins() async throws {
        let result = try await pick(
            video(id: "small-playing", width: 100, height: 60, playing: true)
                + video(id: "big-playing", width: 340, height: 200, playing: true)
                + video(id: "biggest-paused", width: 360, height: 300))
        XCTAssertEqual(result.id, "big-playing")
        XCTAssertTrue(result.playing)
    }

    // MARK: Rule 3 — nothing visible at all

    /// A page whose only video is scrolled away should still pop out, rather
    /// than reporting "no video" at something the page plainly has.
    func testAnEntirelyOffScreenVideoIsStillFound() async throws {
        let result = try await pick(
            video(
                id: "below", width: 300, height: 200,
                style: "position:absolute;top:-3000px;left:0;"))
        XCTAssertEqual(result.id, "below")
        XCTAssertEqual(result.visibleArea, 0, "rule 3 only applies when nothing is on screen")
    }

    func testWithNothingVisibleTheLargestElementWins() async throws {
        let offscreen = "position:absolute;left:-5000px;top:0;"
        let result = try await pick(
            video(id: "small", width: 100, height: 60, style: offscreen)
                + video(id: "large", width: 400, height: 300, style: offscreen))
        XCTAssertEqual(result.id, "large")
    }

    // MARK: Asking for Picture in Picture

    /// The bug this exists to stop coming back: `webkitSetPresentationMode` is
    /// callable on a device with no Picture in Picture and quietly does
    /// nothing. Reporting that as success gives you a menu item that appears
    /// to work and never does. The simulator has no PiP, so here the honest
    /// answer is `unsupported` — and *not* `requested`.
    func testPopOutReportsUnsupportedRatherThanPretending() async throws {
        let result = try await run(
            VideoPopOut.popOutScript, on: video(id: "only", width: 320, height: 180))
        XCTAssertNotEqual(
            result.status, .requested,
            "the simulator cannot do PiP; claiming the request went in is a lie")
        XCTAssertEqual(result.status, .unsupported)
        XCTAssertNotNil(result.message, "an action that did nothing has to say so")
    }

    /// And it still says "no video" rather than "unsupported" when there is
    /// genuinely nothing to pop.
    func testPopOutOnAPageWithNoVideoIsStillNone() async throws {
        let result = try await run(VideoPopOut.popOutScript, on: "<p>Nothing here.</p>")
        XCTAssertEqual(result.status, .none)
    }

    // MARK: Parsing what the page said

    func testParsingAMalformedAnswerIsAFailureRatherThanACrash() {
        XCTAssertEqual(VideoPopOut.Result.parse("not json").status, .failed)
        XCTAssertEqual(VideoPopOut.Result.parse(nil).status, .failed)
        XCTAssertEqual(VideoPopOut.Result.parse(42).status, .failed)
    }

    func testASuccessfulRequestSaysNothing() {
        let result = VideoPopOut.Result(
            status: .requested, index: 0, id: "v", playing: true, candidates: 1)
        XCTAssertNil(result.message, "the video popping out is its own confirmation")
    }

    /// The two "no video" cases read differently on purpose: a page with no
    /// video at all, and a page with videos none of which can be popped.
    func testTheFailureMessagesAreDistinct() {
        let bare = VideoPopOut.Result(
            status: .none, index: -1, id: "", playing: false, candidates: 0)
        let unpoppable = VideoPopOut.Result(
            status: .none, index: -1, id: "", playing: false, candidates: 3)
        XCTAssertEqual(bare.message, "No video on this page.")
        XCTAssertNotEqual(bare.message, unpoppable.message)
        XCTAssertNotNil(
            VideoPopOut.Result(
                status: .unsupported, index: 0, id: "", playing: false, candidates: 1
            ).message)
    }

    // MARK: The scripts themselves

    /// Both scripts must carry the same finder, or the tested decision and the
    /// shipped one drift apart.
    func testBothScriptsShareTheSameFinder() {
        XCTAssertTrue(VideoPopOut.selectionScript.contains("function zenPickVideo()"))
        XCTAssertTrue(VideoPopOut.popOutScript.contains("function zenPickVideo()"))
        XCTAssertTrue(VideoPopOut.popOutScript.contains("webkitSetPresentationMode"))
        XCTAssertTrue(VideoPopOut.popOutScript.contains("requestPictureInPicture"))
        XCTAssertTrue(
            VideoPopOut.popOutScript.contains("webkitSupportsPresentationMode"),
            "the request must be gated on real support, not on the method existing")
    }

    /// The observer has to name the handler the app actually registers, and it
    /// has to report only on transitions.
    func testTheObserverScriptPostsToTheRegisteredHandler() {
        XCTAssertTrue(
            VideoPopOut.mediaObserverScript.contains(
                "messageHandlers.\(MediaSession.messageHandlerName)"))
        XCTAssertTrue(VideoPopOut.mediaObserverScript.contains("if (now === reported) return;"))
    }
}
