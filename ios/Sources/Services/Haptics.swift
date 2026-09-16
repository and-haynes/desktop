//  Haptics.swift
//  One place that decides what the phone feels like.
//
//  Desktop Zen has nothing to port here — a trackpad has no taptic vocabulary
//  worth speaking of, and the desktop UI leans on hover states that a finger
//  never produces. On a phone the haptic *is* the hover state: it is the only
//  way the chrome can answer a touch that lands somewhere the eye is not
//  looking. So this is an adaptation, not a translation.
//
//  Everything funnels through `Haptics.fire(_:)`. Views name a *semantic*
//  event ("a tab was closed"), never a generator, so the mapping from meaning
//  to hardware lives in exactly one table and the user's Off / Subtle / Normal
//  / Rich choice can rewrite it wholesale.

import CoreHaptics
import Foundation
import SwiftUI
import UIKit

// MARK: - The user-facing setting

/// How much of the haptic vocabulary the app uses.
enum HapticLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Nothing, ever. Also what we fall back to on hardware without a Taptic
    /// Engine.
    case off
    /// Only the feedback that carries information a finger would otherwise
    /// miss — gesture thresholds and the outcome of a commit.
    case subtle
    /// The default: the full vocabulary of taps at ordinary strength.
    case normal
    /// Adds the ambient touches (page loaded, chrome moved) and plays the
    /// Core Haptics patterns for the signature moments.
    case rich

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .normal: return "Normal"
        case .rich: return "Rich"
        }
    }

    var detail: String {
        switch self {
        case .off: return "No haptic feedback."
        case .subtle: return "Only gesture thresholds and commits."
        case .normal: return "Taps for the things you do."
        case .rich: return "Adds ambient feedback and textured patterns."
        }
    }

    /// Every impact intensity is scaled by this before it reaches the hardware.
    var intensityScale: Double {
        switch self {
        case .off: return 0
        case .subtle: return 0.62
        case .normal: return 1
        case .rich: return 1
        }
    }

    /// Core Haptics patterns are a Rich-only flourish; everything below plays
    /// the pattern's plain-impact fallback.
    var playsSignatures: Bool { self == .rich }

    func allows(_ tier: HapticTier) -> Bool {
        switch self {
        case .off: return false
        case .subtle: return tier == .essential
        case .normal: return tier != .flourish
        case .rich: return true
        }
    }
}

/// How much an event *needs* to be felt, which is what the level setting
/// filters on.
enum HapticTier: Int, Comparable, Sendable {
    /// Carries information: a gesture crossed its threshold, a commit landed,
    /// a load failed. Survives even at Subtle.
    case essential = 0
    /// Confirms a deliberate action. The bulk of the vocabulary.
    case standard = 1
    /// Ambient — pleasant, never load-bearing. Rich only.
    case flourish = 2

    static func < (lhs: HapticTier, rhs: HapticTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - What the hardware is asked to do

/// Deliberately not UIKit types: a plain value type is `Equatable`, can be
/// recorded in a test, and keeps the event table readable.
enum HapticImpact: String, Equatable, Sendable {
    case light, medium, heavy, rigid, soft

    var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        case .rigid: return .rigid
        case .soft: return .soft
        }
    }
}

enum HapticNotice: String, Equatable, Sendable {
    case success, warning, error

    var uiType: UINotificationFeedbackGenerator.FeedbackType {
        switch self {
        case .success: return .success
        case .warning: return .warning
        case .error: return .error
        }
    }
}

/// The three moments that get a composed Core Haptics pattern rather than a
/// single tap, because they are transitions with a shape to them.
enum HapticSignature: String, Equatable, Sendable {
    /// A space lands: a tick, a short swell, a firmer settle.
    case spaceSettle
    /// A glance card arcs in: a soft rise into a click.
    case glanceOpen
    /// The screen splits in two: one tap, a pause, a second tap.
    case splitEnter
}

/// A single resolved instruction for the Taptic Engine.
enum HapticOutput: Equatable, Sendable {
    case impact(HapticImpact, intensity: Double)
    case selection
    case notice(HapticNotice)
    /// Plays `signature` where Core Haptics is available and the level asks
    /// for it; `fallback` is what a plainer device or level feels instead.
    case signature(HapticSignature, fallback: HapticOutputFallback)
}

/// The non-recursive half of `.signature`'s fallback, so `HapticOutput` stays
/// a flat value.
struct HapticOutputFallback: Equatable, Sendable {
    let impact: HapticImpact
    let intensity: Double

    init(_ impact: HapticImpact, _ intensity: Double = 1) {
        self.impact = impact
        self.intensity = intensity
    }

    var output: HapticOutput { .impact(impact, intensity: intensity) }
}

// MARK: - The vocabulary

/// Every moment in the app that is allowed to make the phone move. Views name
/// one of these; nothing outside this file knows a generator exists.
enum HapticEvent: String, CaseIterable, Equatable, Sendable {
    // Tabs
    case tabSelect
    case tabOpen
    case tabClose
    /// A pinned or essential tab was reset rather than destroyed — a *success*,
    /// because something came back.
    case tabRestore
    case swipeCloseThreshold
    case dragPickup
    case dragDrop

    // Spaces
    case spaceSwitchTick
    case spaceSettle
    case essentialTap
    case pinToggle

    // Omnibox
    case omniboxOpen
    case omniboxClose
    case suggestionPick
    case urlCommit
    case pageLoaded
    case loadError
    case bookmarkAdd
    case bookmarkRemove

    // Chrome
    case sidebarSnap
    case compactBarShow
    case compactBarHide
    case grabberDrag
    case layoutChange
    /// One tap of the navigation helper (#008B9). The page is about to move a
    /// long way on its own; the tap is the only thing confirming you asked.
    case navigationStep
    /// One rung of the page-zoom ladder (#008B7). A discrete change with a
    /// visible result, so it ticks like a picker rather than thumping.
    case textSizeStep

    // Glance / split
    case glanceOpen
    case glanceExpand
    case glanceClose
    case splitEnter
    case splitExit
    case dividerSnap

    // Input
    case longPressMenu
    case shortcut

    var tier: HapticTier {
        switch self {
        // Things a finger would otherwise have to discover by looking.
        case .swipeCloseThreshold, .dragPickup, .dragDrop, .urlCommit, .loadError, .tabRestore:
            return .essential
        // Ambient: nice, never necessary.
        case .pageLoaded, .spaceSettle, .glanceExpand, .compactBarShow, .compactBarHide,
            .grabberDrag, .shortcut:
            return .flourish
        default:
            return .standard
        }
    }

    /// The instruction at full strength. `Haptics` scales and downgrades it.
    var baseOutput: HapticOutput {
        switch self {
        case .tabSelect: return .selection
        case .tabOpen: return .impact(.light, intensity: 0.8)
        case .tabClose: return .impact(.soft, intensity: 0.85)
        case .tabRestore: return .notice(.success)
        case .swipeCloseThreshold: return .impact(.rigid, intensity: 0.9)
        case .dragPickup: return .impact(.medium, intensity: 0.9)
        case .dragDrop: return .impact(.light, intensity: 0.8)

        case .spaceSwitchTick: return .selection
        case .spaceSettle: return .signature(.spaceSettle, fallback: .init(.rigid, 0.8))
        case .essentialTap: return .impact(.light, intensity: 0.7)
        case .pinToggle: return .impact(.medium, intensity: 0.8)

        case .omniboxOpen: return .impact(.soft, intensity: 0.7)
        case .omniboxClose: return .impact(.soft, intensity: 0.5)
        case .suggestionPick: return .selection
        case .urlCommit: return .impact(.light, intensity: 0.9)
        // "Very light": a page finishing is worth acknowledging, not announcing.
        case .pageLoaded: return .impact(.light, intensity: 0.3)
        case .loadError: return .notice(.error)
        case .bookmarkAdd: return .impact(.light, intensity: 0.85)
        case .bookmarkRemove: return .impact(.soft, intensity: 0.7)

        case .sidebarSnap: return .impact(.rigid, intensity: 0.65)
        case .compactBarShow: return .impact(.soft, intensity: 0.5)
        case .compactBarHide: return .impact(.soft, intensity: 0.35)
        case .grabberDrag: return .selection
        case .layoutChange: return .impact(.rigid, intensity: 0.7)
        case .textSizeStep: return .impact(.light, intensity: 0.6)
        case .navigationStep: return .impact(.light, intensity: 0.7)

        case .glanceOpen: return .signature(.glanceOpen, fallback: .init(.medium, 0.8))
        case .glanceExpand: return .impact(.rigid, intensity: 0.8)
        case .glanceClose: return .impact(.soft, intensity: 0.6)
        case .splitEnter: return .signature(.splitEnter, fallback: .init(.medium, 0.85))
        case .splitExit: return .impact(.medium, intensity: 0.7)
        case .dividerSnap: return .selection

        case .longPressMenu: return .impact(.medium, intensity: 0.75)
        case .shortcut: return .selection
        }
    }
}

// MARK: - The backend seam

/// What `Haptics` talks to. The live implementation drives UIKit and Core
/// Haptics; tests substitute a recorder, which is the only way to assert on
/// feedback that by definition leaves no trace on screen.
@MainActor
protocol HapticBackend: AnyObject {
    /// Warm the generator for this output. Cheap, and the difference between a
    /// tap that lands with the gesture and one that lands 80ms late.
    func prepare(_ output: HapticOutput)
    func play(_ output: HapticOutput)
}

/// Records instead of vibrating.
@MainActor
final class RecordingHapticBackend: HapticBackend {
    private(set) var played: [HapticOutput] = []
    private(set) var prepared: [HapticOutput] = []

    func prepare(_ output: HapticOutput) { prepared.append(output) }
    func play(_ output: HapticOutput) { played.append(output) }
    func reset() {
        played.removeAll()
        prepared.removeAll()
    }
}

// MARK: - The service

@MainActor
final class Haptics {
    static let shared = Haptics()

    /// Mirrors `ZenSettings.hapticLevel`; `BrowserState` pushes it here on
    /// launch and whenever it changes.
    var level: HapticLevel = .normal

    /// Set false while the app is not foreground-active. A haptic fired from a
    /// background task is felt as a phantom buzz in someone's pocket.
    var isForeground: Bool = true

    /// Set while a page is being dragged. Scrolling is a continuous gesture and
    /// anything that buzzes during one feels like a fault, so *every* event is
    /// dropped for its duration — including the compact bar appearing, which
    /// is why the bar's haptic is wired to the grabber and not to the scroll.
    var isScrolling: Bool = false

    private let backend: HapticBackend
    private var lastEvent: (event: HapticEvent, at: Date)?
    /// "At most one per event": a second identical event inside this window is
    /// the same user action arriving twice (a gesture end plus the state change
    /// it causes), not two things happening.
    private let coalesceWindow: TimeInterval = 0.06
    private var lastPrepared: [String: Date] = [:]

    init(backend: HapticBackend? = nil) {
        self.backend = backend ?? LiveHapticBackend()
    }

    /// Warm up ahead of a gesture. Safe to call every frame — it throttles.
    func prepare(_ event: HapticEvent) {
        guard level != .off, level.allows(event.tier) else { return }
        let key = event.rawValue
        if let last = lastPrepared[key], Date().timeIntervalSince(last) < 1.5 { return }
        lastPrepared[key] = Date()
        guard let output = resolve(event) else { return }
        backend.prepare(output)
    }

    func prepare(_ events: [HapticEvent]) {
        for event in events { prepare(event) }
    }

    func fire(_ event: HapticEvent) {
        guard level != .off, isForeground, !isScrolling else { return }
        guard level.allows(event.tier) else { return }
        let now = Date()
        if let last = lastEvent, last.event == event,
            now.timeIntervalSince(last.at) < coalesceWindow
        {
            return
        }
        lastEvent = (event, now)
        guard let output = resolve(event) else { return }
        backend.play(output)
    }

    /// Event → instruction, with the level's scaling and signature downgrade
    /// applied. `nil` means "say nothing".
    func resolve(_ event: HapticEvent) -> HapticOutput? {
        guard level != .off else { return nil }
        let scale = level.intensityScale
        switch event.baseOutput {
        case .impact(let style, let intensity):
            return .impact(style, intensity: clamp(intensity * scale))
        case .selection:
            return .selection
        case .notice(let notice):
            return .notice(notice)
        case .signature(let signature, let fallback):
            guard level.playsSignatures else {
                return .impact(fallback.impact, intensity: clamp(fallback.intensity * scale))
            }
            return .signature(signature, fallback: fallback)
        }
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

// MARK: - The live backend

/// UIKit generators plus a Core Haptics engine for the three signatures.
@MainActor
private final class LiveHapticBackend: HapticBackend {
    private var impacts: [HapticImpact: UIImpactFeedbackGenerator] = [:]
    private lazy var selection = UISelectionFeedbackGenerator()
    private lazy var notice = UINotificationFeedbackGenerator()

    /// nil on a device (or simulator) with no Taptic Engine, which is not an
    /// error — the UIKit generators simply become no-ops too.
    private var engine: CHHapticEngine?
    private var engineFailed = false
    private var supportsCoreHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    func prepare(_ output: HapticOutput) {
        switch output {
        case .impact(let style, _):
            generator(style).prepare()
        case .selection:
            selection.prepare()
        case .notice:
            notice.prepare()
        case .signature(_, let fallback):
            generator(fallback.impact).prepare()
            startEngineIfNeeded()
        }
    }

    func play(_ output: HapticOutput) {
        switch output {
        case .impact(let style, let intensity):
            let generator = generator(style)
            generator.impactOccurred(intensity: CGFloat(intensity))
            // Re-arm: a generator goes cold a moment after firing, and these
            // events come in bursts (tab after tab after tab).
            generator.prepare()
        case .selection:
            selection.selectionChanged()
            selection.prepare()
        case .notice(let kind):
            notice.notificationOccurred(kind.uiType)
            notice.prepare()
        case .signature(let signature, let fallback):
            guard supportsCoreHaptics, playPattern(signature) else {
                play(fallback.output)
                return
            }
        }
    }

    private func generator(_ style: HapticImpact) -> UIImpactFeedbackGenerator {
        if let existing = impacts[style] { return existing }
        let generator = UIImpactFeedbackGenerator(style: style.uiStyle)
        impacts[style] = generator
        return generator
    }

    // MARK: Core Haptics

    private func startEngineIfNeeded() {
        guard supportsCoreHaptics, engine == nil, !engineFailed else { return }
        do {
            let engine = try CHHapticEngine()
            // The engine is stopped whenever the app leaves the foreground or
            // a call comes in; without these it silently never works again.
            engine.resetHandler = { [weak self] in
                Task { @MainActor in try? self?.engine?.start() }
            }
            engine.playsHapticsOnly = true
            try engine.start()
            self.engine = engine
        } catch {
            engineFailed = true
        }
    }

    /// Returns false if the pattern could not be played, so the caller can fall
    /// back to a plain impact rather than leaving the moment silent.
    private func playPattern(_ signature: HapticSignature) -> Bool {
        startEngineIfNeeded()
        guard let engine else { return false }
        do {
            let player = try engine.makePlayer(with: try pattern(for: signature))
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            return false
        }
    }

    private func pattern(for signature: HapticSignature) throws -> CHHapticPattern {
        switch signature {
        case .spaceSettle:
            // Tick, swell, settle — the shape of something sliding into place.
            return try CHHapticPattern(
                events: [
                    transient(at: 0, intensity: 0.5, sharpness: 0.8),
                    continuous(at: 0.02, duration: 0.14, intensity: 0.35, sharpness: 0.3),
                    transient(at: 0.16, intensity: 0.85, sharpness: 0.65),
                ], parameters: [])
        case .glanceOpen:
            // A rise into a click: the card arcs in and lands.
            return try CHHapticPattern(
                events: [
                    continuous(at: 0, duration: 0.11, intensity: 0.28, sharpness: 0.2),
                    transient(at: 0.11, intensity: 0.75, sharpness: 0.55),
                ],
                parameters: [])
        case .splitEnter:
            // Two taps with a gap: one screen becoming two.
            return try CHHapticPattern(
                events: [
                    transient(at: 0, intensity: 0.7, sharpness: 0.6),
                    transient(at: 0.09, intensity: 0.7, sharpness: 0.6),
                ], parameters: [])
        }
    }

    private func transient(at time: TimeInterval, intensity: Float, sharpness: Float)
        -> CHHapticEvent
    {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: time)
    }

    private func continuous(
        at time: TimeInterval, duration: TimeInterval, intensity: Float, sharpness: Float
    ) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: time, duration: duration)
    }
}

// MARK: - Call sites

extension View {
    /// Fire an event as a side effect of a value changing. Keeps the call site
    /// declarative where the change is not driven by a button action.
    func zenHaptic<V: Equatable>(_ event: HapticEvent, on value: V) -> some View {
        onChange(of: value) { _, _ in Haptics.shared.fire(event) }
    }
}
