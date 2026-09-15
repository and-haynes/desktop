//  MediaSession.swift
//  Keeping video and audio alive when the app is not (#008B0).
//
//  WKWebView plays media perfectly well while it is on screen and then stops
//  dead the moment the app is backgrounded or the phone is locked. That is not
//  WebKit being difficult: an app gets the *ambient* audio session by default,
//  which is the "my UI makes noises" category — it mixes with other audio and
//  it is silenced by the ringer switch and by the screen going off. A browser
//  playing a video wants the category a video player wants.
//
//  Two halves, and both are needed:
//
//  1. `UIBackgroundModes: audio` in Info.plist — permission to keep running.
//  2. An `AVAudioSession` in `.playback` — the intent to actually do so.
//
//  Neither is claimed at launch. An audio session activated by an app that is
//  not playing anything interrupts whatever *is* playing — open the browser to
//  read an article and your podcast stops. So the session is activated the
//  first time a page starts media and deactivated once nothing is playing,
//  which is what the injected listener in `VideoPopOut.mediaObserverScript` is
//  for: WebKit exposes no "this page started a video" callback, so the page
//  tells us.
//
//  The AVAudioSession calls are behind a protocol so the bookkeeping — when we
//  activate, when we let go — can be tested without a real audio route, which
//  the simulator does not convincingly have.

import AVFoundation
import Foundation
import WebKit

/// The bit of `AVAudioSession` this service needs, so a test can watch it.
protocol AudioSessionBackend: AnyObject {
    func activatePlayback() throws
    func deactivate() throws
}

/// The real one.
final class SystemAudioSessionBackend: AudioSessionBackend {
    func activatePlayback() throws {
        let session = AVAudioSession.sharedInstance()
        // `.playback` is what keeps sound going with the screen off and the
        // ringer switch silenced; `.moviePlayback` is the mode that tells the
        // system this is video, which is also what Picture in Picture wants.
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
    }

    func deactivate() throws {
        // Telling other apps we are done is what lets a paused podcast resume
        // rather than sit there needing a manual nudge.
        try AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
    }
}

/// What a page told us about its media.
enum MediaSignal: String, Equatable, Sendable {
    case playing
    case stopped
}

/// Owns the audio session on behalf of every web view.
///
/// A singleton because the audio session is one global thing — six tabs each
/// deciding whether to activate it would be six views fighting over one
/// switch. The count is of *pages* currently playing, not of play events, so a
/// page that starts three clips and stops two keeps the session.
@MainActor
final class MediaSession: NSObject {
    static let shared = MediaSession()

    /// How many pages report themselves as playing right now.
    private(set) var playingPages: Set<String> = []
    /// Whether we currently hold an active playback session.
    private(set) var isActive = false

    private let backend: AudioSessionBackend

    init(backend: AudioSessionBackend? = nil) {
        self.backend = backend ?? SystemAudioSessionBackend()
        super.init()
    }

    /// A page changed what it is doing. `page` identifies the web view, so two
    /// tabs playing at once is one session rather than two claims on it.
    func note(_ signal: MediaSignal, from page: String) {
        switch signal {
        case .playing: playingPages.insert(page)
        case .stopped: playingPages.remove(page)
        }
        reconcile()
    }

    /// A web view went away without getting the chance to say it had stopped —
    /// an unloaded tab, a closed Glance. Without this the session would be held
    /// open by a page that no longer exists.
    func pageWentAway(_ page: String) {
        guard playingPages.remove(page) != nil else { return }
        reconcile()
    }

    /// Claim or release the session to match what is actually playing. Split
    /// out so it is the *only* place `isActive` changes.
    private func reconcile() {
        let shouldBeActive = !playingPages.isEmpty
        guard shouldBeActive != isActive else { return }
        do {
            if shouldBeActive {
                try backend.activatePlayback()
            } else {
                try backend.deactivate()
            }
            isActive = shouldBeActive
        } catch {
            // A refused audio session means media plays without the background
            // guarantee — worse, but not a reason to take the page down. Leave
            // `isActive` alone so the next signal tries again.
        }
    }
}

// MARK: - The page's side of the conversation

extension MediaSession: WKScriptMessageHandler {
    /// The handler name the injected script posts to. `nonisolated` because
    /// the script that names it is built at type-initialisation time, off the
    /// main actor.
    nonisolated static let messageHandlerName = "zenMedia"

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
            let raw = body["state"] as? String,
            let signal = MediaSignal(rawValue: raw)
        else { return }
        // The page identity is the web view's, not the URL's: a single-page app
        // navigating does not get to leak a second claim on the session.
        note(signal, from: Self.pageIdentity(for: message.webView))
    }

    nonisolated static func pageIdentity(for webView: WKWebView?) -> String {
        guard let webView else { return "unknown" }
        return String(UInt(bitPattern: ObjectIdentifier(webView).hashValue))
    }
}
