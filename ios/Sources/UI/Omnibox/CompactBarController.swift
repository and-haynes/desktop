//  CompactBarController.swift
//  What the URL bar does in compact mode (#008AF, #008DC).
//
//  Zen desktop's compact mode hides the chrome and gives it back on hover. A
//  phone has no hover, and the first translation — "show the whole bar while
//  you scroll, hide it shortly after" — put a full toolbar back on screen for
//  every flick. What you actually want while reading is the page.
//
//  So there are two states:
//
//      hidden  ──grabber──▶  expanded
//         ▲                     │
//         └──── page tap / scroll ┘
//
//  * **hidden** — nothing but the page, and the grabber above the home
//    indicator as the way back.
//  * **expanded** — the full bar, every button.
//
//  There was a third, a bare pill between the two that scrolling summoned
//  (#008AF), but it sat directly above the grabber and the two read as one
//  affordance drawn twice (#008DC). The grabber does the whole job now.
//
//  The rules that matter: *scrolling never expands the bar* (only the grabber
//  does — otherwise reading a long page is a toolbar flashing at you), and an
//  explicit reveal stays expanded until the page is used again. The still
//  timer only hides the initial chrome when compact mode is first enabled.
//
//  The countdown runs on an injected clock so the whole machine is testable in
//  microseconds rather than in multiples of three seconds.

import Foundation

/// The two states the compact bar can be in.
enum CompactBarPhase: String, Equatable, Sendable, CaseIterable {
    case hidden
    case expanded
}

/// The countdown the compact bar runs on.
@MainActor
protocol CompactBarClock: AnyObject {
    /// Start a countdown, replacing any pending one.
    func schedule(after seconds: TimeInterval, _ body: @escaping @MainActor () -> Void)
    func cancel()
}

/// The live clock: a cancellable `Task`.
@MainActor
final class TaskCompactBarClock: CompactBarClock {
    private var task: Task<Void, Never>?

    func schedule(after seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            body()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
final class CompactBarController: ObservableObject {

    /// What the chrome should be showing. `expanded` whenever compact mode is
    /// off, so a view can read this one property and never branch on the
    /// setting itself.
    @Published private(set) var phase: CompactBarPhase = .expanded

    /// How long the initial chrome stays up when entering compact mode.
    var stillDelay: TimeInterval = ZenSettings().compactHideDelay

    private var isHeldOpen = false
    private var isCovered = false

    /// Compact mode's toolbar half. Off means the bar is simply always there.
    var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isHeldOpen = isEnabled && isCovered
            if isEnabled {
                // Entering compact mode should not snatch the bar away
                // mid-thought; it starts whole and falls on the usual timer.
                set(.expanded, haptic: nil)
                startCountdown()
            } else {
                clock.cancel()
                set(.expanded, haptic: nil)
            }
        }
    }

    private let clock: CompactBarClock
    /// Where a haptic goes. Injected so a test can record what the machine
    /// asked for — feedback that by definition leaves no trace on screen.
    private let fire: @MainActor (HapticEvent) -> Void

    init(
        clock: CompactBarClock? = nil,
        fire: (@MainActor (HapticEvent) -> Void)? = nil
    ) {
        self.clock = clock ?? TaskCompactBarClock()
        self.fire = fire ?? { Haptics.shared.fire($0) }
    }

    // MARK: Events

    /// The page is being scrolled. Never brings the bar back — and takes an
    /// expanded bar away, since scrolling the page is not using the bar.
    /// Silently: mid-flick is no time for a buzz, and the bar going is what
    /// you asked for by scrolling.
    func pageDidScroll() {
        guard isEnabled, !isCovered else { return }
        isHeldOpen = false
        clock.cancel()
        set(.hidden, haptic: nil)
    }

    /// Scrolling settled. Nothing to count down from once the bar is hidden,
    /// which `startCountdown` already knows.
    func scrollDidEnd() {
        guard isEnabled else { return }
        startCountdown()
    }

    /// The chrome is being used — a touch on the bar, the omnibox closing.
    /// A deliberate interaction keeps it open until the page is used again.
    /// No haptic: you are already holding the thing that moved.
    func barInteracted() {
        guard isEnabled else { return }
        isHeldOpen = true
        clock.cancel()
        set(.expanded, haptic: nil)
    }

    /// Something is covering the page — the omnibox overlay, Settings, the
    /// history sheet, the tab drawer.
    ///
    /// Keep the chrome open while it is being used, including after closing
    /// the overlay. Scroll notifications can still arrive from a decelerating
    /// page behind the drawer; they must not dismiss the selected chrome.
    func coveredDidChange(_ covered: Bool) {
        guard covered != isCovered else { return }
        isCovered = covered
        barInteracted()
    }

    /// The deliberate reveal from the grabber: the one gesture that expands
    /// the bar. It then behaves like any other chrome touch.
    func grabberRevealed() {
        guard isEnabled else { return }
        isHeldOpen = true
        clock.cancel()
        set(.expanded, haptic: .compactBarShow)
    }

    /// The page was tapped: put the chrome away now rather than on the timer.
    func pageTapped() {
        guard isEnabled, !isCovered, phase != .hidden else { return }
        isHeldOpen = false
        clock.cancel()
        set(.hidden, haptic: .compactBarHide)
    }

    /// The still-timer fired: the bar goes.
    private func timerFired() {
        guard isEnabled, !isHeldOpen, !isCovered else { return }
        set(.hidden, haptic: .compactBarHide)
    }

    // MARK: Plumbing

    private func startCountdown() {
        guard isEnabled, phase != .hidden, !isHeldOpen, !isCovered else {
            clock.cancel()
            return
        }
        clock.schedule(after: max(0.2, stillDelay)) { [weak self] in
            self?.timerFired()
        }
    }

    private func set(_ next: CompactBarPhase, haptic: HapticEvent?) {
        guard next != phase else { return }
        phase = next
        if let haptic { fire(haptic) }
    }
}
