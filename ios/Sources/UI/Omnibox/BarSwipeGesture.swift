//  BarSwipeGesture.swift
//  What a drag on the URL bar means.
//
//  Desktop Zen has no equivalent: the sidebar is always there, or a click away
//  on a button that is always visible. On a phone the bar is the one piece of
//  chrome guaranteed to be under your thumb, which makes it the right place to
//  reach the tab list from — the toolbar button is a 34pt target at the far
//  left of a 6-inch screen.
//
//  The decision is a pure function of the drag so it can be tested without a
//  simulator, and it resolves through a *mapping table* rather than a switch:
//  the planned URL-bar customisation needs to reassign a direction without
//  touching the gesture, and a table is the seam that makes that a one-line
//  change.

import CoreGraphics

/// The four directions a bar drag can resolve to. `nil` where the drag was too
/// small or too slow to mean anything.
enum BarSwipeDirection: String, Equatable, CaseIterable, Sendable {
    case left, right, up, down
}

/// What a bar swipe does. One action today, deliberately named rather than
/// hard-wired so it can become an assignable command later.
enum BarGestureAction: String, Equatable, Sendable {
    case openSidebar
    case closeSidebar
    /// The gesture resolved, but it asked for something already true.
    case none
}

enum BarSwipeGesture {
    /// How far a deliberate, unhurried drag has to travel.
    static let distanceThreshold: CGFloat = 40
    /// A flick counts sooner, but must still have gone somewhere — a 2pt
    /// twitch with a high instantaneous velocity is a tap with shaky hands.
    static let flickDistance: CGFloat = 12
    /// Points per second along the dominant axis.
    static let velocityThreshold: CGFloat = 320

    /// The default direction → action map. Right or up reaches for the tab
    /// list; left or down puts it away, mirroring the drawer's own motion.
    static let defaultMapping: [BarSwipeDirection: BarGestureAction] = [
        .right: .openSidebar,
        .up: .openSidebar,
        .left: .closeSidebar,
        .down: .closeSidebar,
    ]

    /// Which way the drag went, or nil if it did not go far or fast enough.
    /// The dominant axis wins outright, so a diagonal never fires two things.
    static func direction(translation: CGSize, velocity: CGSize) -> BarSwipeDirection? {
        let horizontal = abs(translation.width) >= abs(translation.height)
        let distance = horizontal ? translation.width : translation.height
        let speed = horizontal ? velocity.width : velocity.height

        let travelled = abs(distance) >= distanceThreshold
        let flicked = abs(distance) >= flickDistance && abs(speed) >= velocityThreshold
        guard travelled || flicked else { return nil }
        // A flick whose velocity opposes its travel is the tail of a gesture
        // that already reversed; take the direction the finger actually moved.
        if horizontal { return distance > 0 ? .right : .left }
        return distance > 0 ? .down : .up
    }

    /// The whole decision: direction, mapped action, and the state check that
    /// stops "open" from firing on an already-open sidebar (which would be a
    /// haptic for nothing).
    static func action(
        translation: CGSize, velocity: CGSize, isSidebarOpen: Bool,
        mapping: [BarSwipeDirection: BarGestureAction] = defaultMapping
    ) -> BarGestureAction {
        guard let direction = direction(translation: translation, velocity: velocity),
            let action = mapping[direction]
        else { return .none }
        switch action {
        case .openSidebar: return isSidebarOpen ? .none : .openSidebar
        case .closeSidebar: return isSidebarOpen ? .closeSidebar : .none
        case .none: return .none
        }
    }
}
