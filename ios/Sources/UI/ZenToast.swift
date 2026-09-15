//  ZenToast.swift
//  A sentence that appears, is read, and goes (#008B0).
//
//  Added for "Pop out video": the action succeeds visibly — the video pops out —
//  but its *failures* are silent, and an action that does nothing at all reads
//  as a broken button. An alert would be too much for "no video on this page";
//  a haptic alone says something happened without saying what.
//
//  Deliberately small: one line of text, no buttons, no queue. A second toast
//  replaces the first rather than waiting behind it, because the newest message
//  is the one that describes what you just did.

import SwiftUI

/// A transient message. Identified so that re-posting the same text restarts
/// the timer rather than being ignored as "no change".
struct ZenToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String?

    init(_ text: String, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }
}

struct ZenToast: View {
    let message: ZenToastMessage
    @Environment(\.zenPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            if let symbol = message.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
            }
            Text(message.text)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(palette.text.color)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: 320)
        .zenSurface(palette, radius: 14, elevated: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("zenToast")
        .accessibilityLabel(message.text)
        // Announced as well as shown: a message that only exists for two
        // seconds is no use to someone who is not looking at the screen.
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The toast, positioned and timed.
///
/// A view in the root's overlay stack rather than a `.overlay` modifier on the
/// root's outer chain, which is where this started and did not work: the root
/// ignores the bottom safe area so the page can run under the home indicator,
/// so an overlay hung on the *outside* of that chain lands below the bar and
/// half off the screen — and it misses `zenPalette`, which is set inside the
/// chain, so it draws in the default colours as well. Both go away by living
/// where the compact grabber lives.
struct ZenToastOverlay: View {
    @Binding var message: ZenToastMessage?
    @Environment(\.zenPalette) private var palette

    /// Long enough to read a short sentence twice, short enough not to sit over
    /// the bar while you are trying to use it.
    private static let duration: TimeInterval = 2.6

    var body: some View {
        VStack {
            Spacer()
            if let message {
                ZenToast(message: message)
                    // Clear of the bar, which is what you were just using.
                    .padding(.bottom, 92)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: message)
        // Keyed on the message's identity, so a replacement restarts the
        // countdown instead of inheriting the first one's remaining time.
        .task(id: message?.id) {
            guard message != nil else { return }
            try? await Task.sleep(for: .seconds(Self.duration))
            guard !Task.isCancelled else { return }
            message = nil
        }
        // No `allowsHitTesting(false)` here, though the instinct is right: a
        // `Spacer` has nothing to hit, so the full-height stack does not
        // swallow taps on the page anyway — and turning hit testing off takes
        // the toast out of XCUITest's reach as well, which cost a UI test that
        // could see the toast in a screenshot and not in a query.
    }
}
