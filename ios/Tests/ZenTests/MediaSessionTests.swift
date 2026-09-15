//  MediaSessionTests.swift
//  When the audio session is claimed, and when it is let go (#008B0).
//
//  The rule this suite exists to protect is the polite one: the browser does
//  not take the audio session just because it launched. It takes it when a page
//  starts playing and gives it back when nothing is. Getting that wrong is not
//  a subtle bug — it stops whatever the phone was already playing the moment
//  you open a tab.

import WebKit
import XCTest

@testable import Zen

@MainActor
final class MediaSessionTests: XCTestCase {

    /// Records what the service asked the system for, without asking the
    /// system — the simulator has no audio route worth the name.
    private final class RecordingBackend: AudioSessionBackend {
        enum Call: Equatable { case activate, deactivate }
        var calls: [Call] = []
        /// Set to make the next call throw, as a busy system would.
        var failNext = false

        func activatePlayback() throws {
            if failNext {
                failNext = false
                throw NSError(domain: "test", code: 1)
            }
            calls.append(.activate)
        }

        func deactivate() throws {
            if failNext {
                failNext = false
                throw NSError(domain: "test", code: 1)
            }
            calls.append(.deactivate)
        }
    }

    private var backend: RecordingBackend!

    private func makeSession() -> MediaSession {
        backend = RecordingBackend()
        return MediaSession(backend: backend)
    }

    // MARK: The polite default

    func testNothingIsClaimedUntilSomethingPlays() {
        let session = makeSession()
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(backend.calls, [], "launching the browser must not interrupt anything")
    }

    func testPlayingClaimsTheSessionAndStoppingGivesItBack() {
        let session = makeSession()
        session.note(.playing, from: "tab-a")
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(backend.calls, [.activate])

        session.note(.stopped, from: "tab-a")
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(backend.calls, [.activate, .deactivate])
    }

    // MARK: One session, many pages

    /// The audio session is one global switch. Two tabs playing is one claim,
    /// not two, and the claim only drops when the last of them stops.
    func testTwoPlayingTabsAreOneClaim() {
        let session = makeSession()
        session.note(.playing, from: "tab-a")
        session.note(.playing, from: "tab-b")
        XCTAssertEqual(backend.calls, [.activate], "the second tab must not re-activate")

        session.note(.stopped, from: "tab-a")
        XCTAssertTrue(session.isActive, "tab-b is still playing")
        XCTAssertEqual(backend.calls, [.activate])

        session.note(.stopped, from: "tab-b")
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(backend.calls, [.activate, .deactivate])
    }

    /// A page that reports `playing` twice — a second clip starting on the same
    /// page — is still one page.
    func testRepeatedSignalsFromOnePageDoNotStack() {
        let session = makeSession()
        session.note(.playing, from: "tab-a")
        session.note(.playing, from: "tab-a")
        session.note(.stopped, from: "tab-a")
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(backend.calls, [.activate, .deactivate])
    }

    /// The leak this guards: a tab unloaded mid-playback never gets to say it
    /// stopped, and its claim would hold the session open forever.
    func testAnUnloadedPageReleasesItsClaim() {
        let session = makeSession()
        session.note(.playing, from: "tab-a")
        session.pageWentAway("tab-a")
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(backend.calls, [.activate, .deactivate])
    }

    func testAPageThatWasNotPlayingGoingAwayChangesNothing() {
        let session = makeSession()
        session.note(.playing, from: "tab-a")
        backend.calls = []
        session.pageWentAway("tab-b")
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(backend.calls, [])
    }

    // MARK: When the system says no

    /// A refused session means media plays without the background guarantee.
    /// That is worse, not fatal — and the next signal should try again rather
    /// than the service believing it holds something it does not.
    func testARefusedActivationIsRetriedOnTheNextSignal() {
        let session = makeSession()
        backend.failNext = true
        session.note(.playing, from: "tab-a")
        XCTAssertFalse(session.isActive)

        session.note(.playing, from: "tab-b")
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(backend.calls, [.activate])
    }
}

// MARK: - The web view's side

@MainActor
final class MediaConfigurationTests: XCTestCase {

    /// Every one of these is something a browser has to allow and WebKit does
    /// not by default. They are asserted rather than trusted because they are
    /// invisible until a video fails to play, at which point the cause is four
    /// layers away from the symptom.
    func testTheMediaPolicyIsAppliedToAConfiguration() {
        let config = WKWebViewConfiguration()
        WebEngine.applyMediaPolicy(to: config)

        XCTAssertTrue(config.allowsInlineMediaPlayback, "video must play in the page")
        XCTAssertTrue(config.allowsPictureInPictureMediaPlayback, "PiP is the whole ticket")
        XCTAssertTrue(config.allowsAirPlayForMediaPlayback)
        XCTAssertTrue(
            config.preferences.isElementFullscreenEnabled,
            "a site's own full-screen button goes through requestFullscreen()")
    }

    /// The subtle one. `.audio` sounds like the polite setting and is the
    /// broken one: it makes a *muted* autoplaying clip wait for a tap that
    /// never comes, so half the web's page furniture sits black.
    func testAPageDecidesForItselfWhenToStartPlaying() {
        let config = WKWebViewConfiguration()
        WebEngine.applyMediaPolicy(to: config)
        XCTAssertTrue(
            config.mediaTypesRequiringUserActionForPlayback.isEmpty,
            "requiring a gesture for .audio breaks muted autoplay as well")
    }

    /// Configuration alone is not enough — the page has to be able to tell us
    /// it started, or the audio session is never claimed.
    func testTheObserverScriptAndItsHandlerAreInstalled() {
        let config = WKWebViewConfiguration()
        WebEngine.applyMediaPolicy(to: config)
        let scripts = config.userContentController.userScripts
        XCTAssertTrue(
            scripts.contains { $0.source == VideoPopOut.mediaObserverScript },
            "the media observer must be injected into every page")
        XCTAssertTrue(
            scripts.contains {
                $0.source == VideoPopOut.mediaObserverScript && !$0.isForMainFrameOnly
            },
            "a same-origin iframe player has to report too")
    }
}
