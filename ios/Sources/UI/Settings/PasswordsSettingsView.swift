//  PasswordsSettingsView.swift
//  Settings → Passwords (#008AB).
//
//  Zen for iOS has no password manager of its own, and on iOS a third-party
//  browser does not get to have one that other apps' managers plug into. What
//  it gets is **system Password AutoFill**: iOS puts a key in the keyboard's
//  shortcut bar above a login form in a `WKWebView`, and whichever app is set
//  as the AutoFill provider — iCloud Passwords, 1Password, Bitwarden — fills
//  it. Firefox for iOS works exactly this way.
//
//  So this screen's job is to explain where the control actually lives and to
//  get someone there in as few taps as iOS allows, which is not as few as we
//  would like: `UIApplication.openSettingsURLString` opens **Zen's own**
//  settings page, and there is no public URL for the AutoFill pane. The path
//  is therefore written out rather than linked, because a button that lands
//  somewhere else is worse than an instruction.
//
//  What the app must *not* do is in `WebEngine.swift` and `WebView.swift`: no
//  custom `inputAccessoryView` or `inputAssistantItem` on the web view or its
//  scroll view, no user scripts that touch forms or focus, and nothing that
//  takes first responder off a focused field. Each of those removes the key.

import SwiftUI
import UIKit

struct PasswordsSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                PasswordsSettingsView()
            } label: {
                Label("Passwords", systemImage: "key.fill")
            }
            .accessibilityIdentifier("passwordsSettingsLink")
        } footer: {
            Text(
                "Zen fills logins through iOS Password AutoFill, so your password manager "
                    + "works here as it does in Safari.")
        }
    }
}

struct PasswordsSettingsView: View {
    @Environment(\.zenPalette) private var palette

    var body: some View {
        Form {
            Section {
                // Plain text, not Markdown: `Text` only parses Markdown from a
                // *literal*, and this string is concatenated — the asterisks
                // would render as asterisks.
                Text(
                    "Zen does not keep passwords. It uses Password AutoFill, which is "
                        + "iOS's own: tap a login field on a page and the key above the "
                        + "keyboard offers the accounts your password manager holds for that "
                        + "site. Whatever you have set as the AutoFill provider — iCloud "
                        + "Passwords, 1Password, Bitwarden — is what answers.")
                .font(.callout)
            } header: {
                Text("How passwords work here")
            } footer: {
                Text(
                    "This is the only route iOS gives a third-party browser. An app cannot "
                        + "read another app's vault, and there is no browser-extension model "
                        + "on iOS — Firefox for iOS fills logins the same way.")
            }

            Section {
                ForEach(Array(Self.autoFillPath.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(palette.accent.color)
                            .frame(width: 16, alignment: .trailing)
                        Text(step)
                            .font(.callout)
                    }
                }
            } header: {
                Text("Choose your provider")
            } footer: {
                Text(
                    "Written out rather than linked: iOS publishes no URL for the AutoFill "
                        + "pane, and the button below can only open Zen's own settings page. "
                        + "The wording moved in iOS 18 — on iOS 17 it is Settings → "
                        + "Passwords → Password Options.")
            }

            Section {
                Button {
                    Haptics.shared.fire(.tabSelect)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Zen in iOS Settings", systemImage: "arrow.up.forward.app")
                }
                .accessibilityIdentifier("passwordsOpenSettingsButton")
            } footer: {
                Text(
                    "Opens Zen's page in Settings. From there, go back once to reach "
                        + "Settings itself, then follow the steps above.")
            }

            Section {
                LabeledContent("Passkeys", value: "Supported by the system")
                LabeledContent("Saved passwords", value: "Held by your provider")
                LabeledContent("Zen's own vault", value: "None")
            } header: {
                Text("What Zen stores")
            } footer: {
                Text(
                    "Passkeys work because WebKit implements WebAuthn: pages in Zen can call "
                        + "navigator.credentials, and iOS puts up its own sheet to choose a "
                        + "passkey — Zen neither sees nor stores it. Zen keeps no passwords "
                        + "of its own at all; the only secrets it holds are the Mozilla "
                        + "account's sync keys, in the keychain.")
            }
        }
        .navigationTitle("Passwords")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("passwordsSettingsView")
    }

    /// iOS 18 and later. Kept as data so the numbering is not hand-maintained.
    static let autoFillPath = [
        "Open the iOS Settings app.",
        "Go to General → AutoFill & Passwords.",
        "Turn on AutoFill From, and tick your password manager (1Password, "
            + "Bitwarden, iCloud Passwords…).",
        "Come back to Zen. The key above the keyboard now offers that manager's logins.",
    ]
}
