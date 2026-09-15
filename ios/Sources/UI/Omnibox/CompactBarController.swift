//  CompactBarController.swift
//  What the URL bar does in compact mode (#008AF).
//
//  Zen desktop's compact mode hides the chrome and gives it back on hover. A
//  phone has no hover, and the first translation — "show the whole bar while
//  you scroll, hide it shortly after" — put a full toolbar back on screen for
//  every flick. What you actually want while reading is the page, with just
//  enough left to know where you are.
//
//  So there are three states rather than two:
//
//      hidden  ──scroll──▶  pill  ──tap──▶  expanded
//         ▲                  │ ▲              │
//         └──── still ───────┘ └──── still ───┘
//
//  * **hidden** — nothing but the page. The grabber above the home indicator
//    stays as the fallback way back.
//  * **pill** — favicon and domain, nothing else. Where you are, and no more.
//  * **expanded** — the full bar, every button.
//
//  The two rules that matter: *scrolling never expands the bar* (only a tap
//  does — otherwise reading a long page is a toolbar flashing at you), and
//  every state falls one step at a time down the same still-timer, so there is
//  one number in Settings rather than three.
//
//  The countdown runs on an injected clock so the whole machine is testable in
//  microseconds rather than in multiples of three seconds.

import Foundation

/// The three states the compact bar can be in.
enum CompactBarPhase: String, Equatable, Sendable, CaseIterable {
    case hidden
    case pill
    case expanded

    /// One step closer to gone. `hidden` is the floor.
    var collapsed: CompactBarPhase {
        switch self {
        case .expanded: return .pill
        case .pill: return .hidden
        case .hidden: return .hidden
        }
    }
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

    /// How long "still" is, in seconds. The same number governs every step of
    /// the ladder, so the bar always fades at the rate Settings advertises.
    var stillDelay: TimeInterval = ZenSettings().compactHideDelay

    /// Compact mode's toolbar half. Off means the bar is simply always there.
    var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
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

    /// The page is being scrolled. Brings the bar back as far as the *pill*
    /// and no further — and takes an expanded bar back down to the pill, since
    /// scrolling the page is not using the bar.
    func pageDidScroll() {
        guard isEnabled else { return }
        clock.cancel()
        switch phase {
        case .hidden: set(.pill, haptic: .compactBarShow)
        case .expanded: set(.pill, haptic: nil)
        case .pill: break
        }
    }

    /// Scrolling settled. Everything from here is the still-timer.
    func scrollDidEnd() {
        guard isEnabled else { return }
        startCountdown()
    }

    /// The collapsed pill was tapped: the one gesture that expands the bar.
    func pillTapped() {
        guard isEnabled else { return }
        set(.expanded, haptic: .compactBarExpand)
        startCountdown()
    }

    /// The chrome is being used — a touch on the bar, the omnibox closing.
    /// Keeps it whole for as long as you are working with it, and fires no
    /// haptic: you are already holding the thing that moved.
    func barInteracted() {
        guard isEnabled else { return }
        set(.expanded, haptic: nil)
        startCountdown()
    }

    /// Something is covering the page — the omnibox overlay, Settings, the
    /// history sheet, the tab drawer.
    ///
    /// While one of those is up the bar is not on screen to fall, so the
    /// countdown is *paused* rather than left running. Two reasons, and the
    /// second is the one that bites: a timer firing behind an overlay buzzes a
    /// hide haptic at someone who is mid-word in the search field, and a bar
    /// that quietly collapsed while you were reading a sheet is gone when you
    /// come back from it — which reads as the app having lost your place.
    /// Uncovering hands the bar back whole for the same reason.
    ///
    /// SwiftUI's `Menu` is the gap: it reports nothing about being open, so the
    /// overflow menu cannot pause the timer. Its items still work — a menu is
    /// its own presentation — but the bar behind it may have collapsed by the
    /// time it closes.
    func coveredDidChange(_ covered: Bool) {
        guard isEnabled else { return }
        if covered {
            clock.cancel()
            set(.expanded, haptic: nil)
        } else {
            barInteracted()
        }
    }

    /// The deliberate reveal from the grabber. Goes straight to the full bar,
    /// and then behaves like any other chrome touch.
    func grabberRevealed() {
        guard isEnabled else { return }
        set(.expanded, haptic: .compactBarShow)
        startCountdown()
    }

    /// The page was tapped: put the chrome away now rather than on the timer.
    func pageTapped() {
        guard isEnabled, phase != .hidden else { return }
        clock.cancel()
        set(.hidden, haptic: .compactBarHide)
    }

    /// The still-timer fired: fall one step.
    private func timerFired() {
        guard isEnabled else { return }
        let next = phase.collapsed
        guard next != phase else { return }
        set(next, haptic: next == .hidden ? .compactBarHide : nil)
        // The ladder has another rung below `pill`, so keep counting.
        if next != .hidden { startCountdown() }
    }

    // MARK: Plumbing

    private func startCountdown() {
        guard isEnabled, phase != .hidden else {
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
