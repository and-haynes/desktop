//  VideoPopOut.swift
//  "Pop out video" — Picture in Picture on demand (#008B0).
//
//  WebKit will put a video into Picture in Picture, but only from its *own*
//  controls: the little PiP glyph in the native player. Plenty of sites hide
//  those controls and draw their own, and then there is no way to pop the video
//  out at all — which is the thing people actually want a browser to do on a
//  phone, because it is how you keep watching while you do something else.
//
//  There is no API for "put this page's video into PiP" from the app side, so
//  the page has to do it, and the only question is *which* video. A modern page
//  has several: the one you are watching, three autoplaying muted clips in the
//  sidebar, and an invisible one the ad stack left behind. So:
//
//  1. **Playing beats not playing.** If anything is playing, the answer is
//     among those and nowhere else.
//  2. **Then largest visible.** Visible area on screen, not intrinsic size — a
//     1080p video scrolled off the top is not what you are looking at.
//  3. **Then largest, full stop**, so a page whose only video is just off
//     screen still pops out rather than doing nothing.
//
//  The finder is shared verbatim between the script that *chooses* and the
//  script that chooses *and acts*, so the tested code path is the shipped one:
//  `selectionScript` returns the decision as JSON and is what the fixture tests
//  drive, and `popOutScript` is that same function followed by the PiP call.
//
//  Cross-origin iframes are out of reach and always will be — a page that
//  embeds YouTube via `<iframe>` gets "no video" here, because scripts cannot
//  see into another origin's document. YouTube's own mobile site plays in a
//  same-origin `<video>` and works.
//
//  One environment note, because it cost an hour: **the iOS Simulator has no
//  Picture in Picture.** `document.pictureInPictureEnabled` is false and
//  `webkitSupportsPresentationMode("picture-in-picture")` returns false, while
//  `webkitSetPresentationMode` is still a perfectly callable function that
//  silently does nothing. So the request is gated on the support check rather
//  than on the method existing, and the simulator honestly reports
//  `unsupported`. The floating-window half can only be seen on hardware.

import Foundation

enum VideoPopOut {

    /// The shared decision. Defines `zenPickVideo()` and `zenDescribeVideo()`;
    /// the two scripts below differ only in what they do with the answer.
    private static let finder = """
        function zenVisibleArea(v) {
          var r = v.getBoundingClientRect();
          var w = Math.min(r.right, window.innerWidth) - Math.max(r.left, 0);
          var h = Math.min(r.bottom, window.innerHeight) - Math.max(r.top, 0);
          return w > 0 && h > 0 ? w * h : 0;
        }
        function zenElementArea(v) {
          var r = v.getBoundingClientRect();
          return Math.max(r.width, 0) * Math.max(r.height, 0);
        }
        // Deliberately the two standard properties and nothing else. `readyState`
        // would be more precise about "really playing", but it also makes the
        // rule untestable without shipping real media into a fixture, and a
        // video that is un-paused and un-ended is what a person means by playing.
        function zenIsPlaying(v) {
          return !v.paused && !v.ended;
        }
        function zenAllVideos() {
          return Array.prototype.slice.call(document.querySelectorAll("video"));
        }
        function zenPickVideo() {
          var all = zenAllVideos();
          if (!all.length) return null;
          // Rule 1: playing wins outright.
          var playing = all.filter(zenIsPlaying);
          var pool = playing.length ? playing : all;
          // Rule 2: among those, the largest actually on screen.
          var visible = pool.filter(function (v) { return zenVisibleArea(v) > 0; });
          // Rule 3: nothing on screen — fall back to the largest element.
          var ranked = visible.length ? visible : pool;
          var measure = visible.length ? zenVisibleArea : zenElementArea;
          var best = ranked[0];
          for (var i = 1; i < ranked.length; i++) {
            if (measure(ranked[i]) > measure(best)) best = ranked[i];
          }
          return best;
        }
        function zenDescribeVideo(v) {
          var all = zenAllVideos();
          return {
            found: true,
            index: all.indexOf(v),
            id: v.id || "",
            playing: zenIsPlaying(v),
            visibleArea: Math.round(zenVisibleArea(v)),
            elementArea: Math.round(zenElementArea(v)),
            candidates: all.length
          };
        }
        """

    /// Which video would be popped out, as JSON — the decision with no side
    /// effects, which is what the fixture tests drive.
    static let selectionScript = """
        (function () {
          \(finder)
          var v = zenPickVideo();
          return JSON.stringify(v ? zenDescribeVideo(v) : { found: false, candidates: zenAllVideos().length });
        })()
        """

    /// The decision, and then the request. Returns the same JSON with a
    /// `status` so the caller knows whether to say anything.
    static let popOutScript = """
        (function () {
          \(finder)
          var v = zenPickVideo();
          if (!v) return JSON.stringify({ found: false, status: "none", candidates: 0 });
          var out = zenDescribeVideo(v);
          try {
            // Ask before telling. `webkitSetPresentationMode` exists whether or
            // not this device can actually do Picture in Picture, and calling
            // it where it cannot does *nothing at all* — no throw, no rejected
            // promise, no change of mode. Reporting that as success is how you
            // get a menu item that appears to work and never does; the
            // simulator, which has no PiP at all, is the case that found it.
            var mode = "picture-in-picture";
            var canWebkit =
              typeof v.webkitSetPresentationMode === "function" &&
              (typeof v.webkitSupportsPresentationMode !== "function" ||
                v.webkitSupportsPresentationMode(mode) === true);
            var canStandard =
              typeof v.requestPictureInPicture === "function" &&
              document.pictureInPictureEnabled !== false &&
              v.disablePictureInPicture !== true;
            if (canWebkit) {
              v.webkitSetPresentationMode(mode);
              out.status = "requested";
              out.api = "webkit";
            } else if (canStandard) {
              v.requestPictureInPicture();
              out.status = "requested";
              out.api = "standard";
            } else {
              out.status = "unsupported";
            }
          } catch (e) {
            out.status = "failed";
            out.message = String(e);
          }
          return JSON.stringify(out);
        })()
        """

    /// Injected into every page so `MediaSession` knows when to claim the audio
    /// session. WebKit has no delegate callback for "this page started playing
    /// something", so the page reports it.
    ///
    /// The listeners are registered in the *capture* phase on `document`:
    /// media events do not bubble, so a listener on the document only sees them
    /// on the way down. That is also what makes one listener cover videos added
    /// to the page later, which on a single-page app is all of them.
    static let mediaObserverScript = """
        (function () {
          if (window.__zenMediaObserver) return;
          window.__zenMediaObserver = true;
          var reported = false;
          function anyPlaying() {
            var media = document.querySelectorAll("video, audio");
            for (var i = 0; i < media.length; i++) {
              if (!media[i].paused && !media[i].ended) return true;
            }
            return false;
          }
          function report() {
            var now = anyPlaying();
            // Only transitions, or a video firing timeupdate would post sixty
            // messages a second across the bridge.
            if (now === reported) return;
            reported = now;
            try {
              window.webkit.messageHandlers.\(MediaSession.messageHandlerName)
                .postMessage({ state: now ? "playing" : "stopped" });
            } catch (e) {}
          }
          ["play", "playing", "pause", "ended", "emptied"].forEach(function (name) {
            document.addEventListener(name, report, true);
          });
        })();
        """

    // MARK: - The answer

    /// What the page said. A value rather than a dictionary so the call sites
    /// and the tests agree on what the fields mean.
    struct Result: Equatable {
        enum Status: String, Equatable {
            /// The request went in. PiP itself is asynchronous and the system
            /// may still refuse it.
            case requested
            /// There was no video to pop out.
            case none
            /// A video, but this WebKit has no PiP API for it.
            case unsupported
            /// The call threw.
            case failed
        }

        var status: Status
        var index: Int
        var id: String
        var playing: Bool
        var candidates: Int
        /// How much of the chosen video is actually on screen, in square
        /// points. Zero means rule 3 fired — the only video is scrolled away.
        var visibleArea: Int = 0

        /// What to put in the toast, or nil when nothing needs saying — a
        /// request that went in speaks for itself, because the video visibly
        /// pops out.
        var message: String? {
            switch status {
            case .requested: return nil
            case .none:
                return candidates == 0
                    ? "No video on this page."
                    : "No video here that can be popped out."
            case .unsupported: return "This video cannot be popped out."
            case .failed: return "Could not pop out this video."
            }
        }

        /// Parse the JSON the scripts return. Anything unreadable is a failure
        /// rather than a crash: this is a string that came from a web page.
        static func parse(_ raw: Any?) -> Result {
            guard let string = raw as? String,
                let data = string.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return Result(status: .failed, index: -1, id: "", playing: false, candidates: 0)
            }
            let found = json["found"] as? Bool ?? false
            let status =
                Status(rawValue: json["status"] as? String ?? "") ?? (found ? .failed : .none)
            return Result(
                status: status,
                index: json["index"] as? Int ?? -1,
                id: json["id"] as? String ?? "",
                playing: json["playing"] as? Bool ?? false,
                candidates: json["candidates"] as? Int ?? 0,
                visibleArea: json["visibleArea"] as? Int ?? 0)
        }
    }
}
