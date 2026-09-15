//  FocusChrome.swift
//  The bits of UI that only exist in Focus mode.
//
//  Firefox Focus's signature interaction is the erase button: one obvious,
//  always-present trash control, and a short confirmation that the session is
//  gone. Everything here exists to make that gesture feel trustworthy — which
//  means the button is prominent, the confirmation is explicit, and the mode
//  is visually unmistakable so you never think you are private when you are not.

import SwiftUI
import LocalAuthentication

/// The trash button that lives in the bar while Focus is on.
struct FocusEraseButton: View {
    @ObservedObject var state: BrowserState
    @Environment(\.zenPalette) private var palette

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                state.eraseFocus()
            }
        } label: {
            Image(systemName: "trash.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 36)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.accent.color)
                }
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityLabel("Erase browsing session")
    }
}

/// "Your browsing history has been erased." Brief, centred, unmissable.
struct FocusToast: View {
    let message: String
    @Environment(\.zenPalette) private var palette

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            Capsule().fill(palette.accent.mix(.black, weight: 0.75).color)
        }
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5) }
        .zenBigShadow()
        .padding(.horizontal, 24)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Covers Focus content when the app comes back from the background and the
/// owner has asked for biometrics.
struct FocusLockScreen: View {
    @ObservedObject var state: BrowserState
    @Environment(\.zenPalette) private var palette
    @State private var failed = false

    var body: some View {
        ZStack {
            // A full cover, not a blur: the point is that nothing is readable
            // over someone's shoulder before the owner authenticates.
            palette.brandingBG.color.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(palette.accent.color)
                Text("Focus is locked")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.text.color)
                Text("Unlock to return to your private session.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary.color)
                Button {
                    authenticate()
                } label: {
                    Text(failed ? "Try again" : "Unlock")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 30)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(palette.accent.color))
                }
                .buttonStyle(ZenPressStyle(pressedScale: 0.98))

                Button("Erase and leave Focus") {
                    state.exitFocusMode()
                }
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary.color)
            }
        }
        .onAppear { authenticate() }
    }

    private func authenticate() {
        Task {
            let ok = await FocusLock.authenticate()
            await MainActor.run {
                if ok {
                    withAnimation(.easeOut(duration: 0.2)) { state.focusLocked = false }
                } else {
                    failed = true
                }
            }
        }
    }
}

enum FocusLock {
    /// True when the device can actually do this. The simulator usually cannot,
    /// so callers must treat "unavailable" as "do not lock" rather than
    /// "lock forever with no way out".
    static var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Returns true if the owner authenticated, or if no authentication is
    /// possible on this device — failing open here is deliberate: a simulator
    /// or a passcode-less device must not be locked out of its own tabs.
    static func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        var error: NSError?
        // `deviceOwnerAuthentication` falls back to the passcode, so this only
        // gives up when there is no authentication configured at all.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your Focus session"
            ) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
