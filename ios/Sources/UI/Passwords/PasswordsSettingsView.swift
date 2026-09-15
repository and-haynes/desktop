//  PasswordsSettingsView.swift
//  Settings → Passwords: both halves of the password story (#008AB, #008AD).
//
//  There are genuinely two, and conflating them is how this screen would get
//  confusing:
//
//   1. **iOS Password AutoFill** — the key above the keyboard, filled by
//      whichever app is the system AutoFill provider. Zen neither sees nor
//      stores anything; it just has to not break it, which is #008AB's audit.
//      This works on every branch and needs no setup here, only an explanation
//      of where the setting actually lives, because iOS publishes no URL for
//      the AutoFill pane.
//   2. **Zen's own vault connection** — 1Password Connect or Vaultwarden,
//      talked to directly over the network. This is the experimental half: it
//      reaches vaults AutoFill cannot, it can put a one-time code into a page,
//      and the price is that Zen handles plaintext secrets.
//
//  So the screen is ordered vault-first (it is the thing with controls) and
//  AutoFill second (it is the thing with instructions), with a plain statement
//  of which is which at the top of each.

import LocalAuthentication
import SwiftUI
import UIKit

// MARK: - The Settings row

struct PasswordsSettingsSection: View {
    @ObservedObject var vault: PasswordVaultService

    var body: some View {
        Section {
            NavigationLink {
                PasswordsSettingsView(vault: vault)
            } label: {
                Label("Passwords", systemImage: "key.fill")
            }
            .accessibilityIdentifier("passwordsSettingsLink")
        } footer: {
            Text(
                vault.isConfigured
                    ? "Connected to \(vault.configuration?.kind.displayName ?? "a vault"), plus "
                        + "iOS Password AutoFill."
                    : "Zen fills logins through iOS Password AutoFill. A 1Password or Vaultwarden "
                        + "connection can be added here.")
        }
    }
}

// MARK: - The screen

struct PasswordsSettingsView: View {
    @ObservedObject var vault: PasswordVaultService
    @Environment(\.zenPalette) private var palette

    @State private var isSetUpPresented = false
    @State private var isForgetConfirmed = false

    var body: some View {
        Form {
            vaultSection
            if vault.isConfigured {
                statusSection
                controlsSection
            }
            autoFillSection
            autoFillPathSection
            storesSection
        }
        .navigationTitle("Passwords")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("passwordsSettingsView")
        .sheet(isPresented: $isSetUpPresented) {
            VaultSetUpSheet(vault: vault).environment(\.zenPalette, palette)
        }
        .confirmationDialog(
            "Forget this vault?", isPresented: $isForgetConfirmed, titleVisibility: .visible
        ) {
            Button("Forget Vault", role: .destructive) { vault.forgetVault() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes the saved credentials and the cached index from this device. Nothing in "
                    + "the vault itself is touched.")
        }
    }

    // MARK: Vault

    @ViewBuilder
    private var vaultSection: some View {
        Section {
            if let configuration = vault.configuration {
                LabeledContent("Provider", value: configuration.kind.displayName)
                LabeledContent("Server", value: configuration.serverURL)
                if let email = configuration.accountEmail, !email.isEmpty {
                    LabeledContent("Account", value: email)
                }
                Button("Change Connection…") { isSetUpPresented = true }
                    .accessibilityIdentifier("passwordsChangeConnection")
            } else {
                Button {
                    isSetUpPresented = true
                } label: {
                    Label("Connect a Vault…", systemImage: "link")
                }
                .accessibilityIdentifier("passwordsConnectVault")
            }
        } header: {
            Text("Zen's vault connection")
        } footer: {
            Text(
                "Experimental (#008AD). Zen talks to 1Password Connect or Vaultwarden itself, so "
                    + "it can list logins for the page you are on and fill them — including "
                    + "one-time codes, which AutoFill cannot do. Unlike AutoFill, this means Zen "
                    + "handles your passwords directly.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            LabeledContent("Logins") {
                Text(vault.lastSyncItemCount.map(String.init) ?? "—")
            }
            LabeledContent("Last synced") {
                Text(
                    vault.lastSyncedAt.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "Never")
            }
            if vault.skippedItemCount > 0 {
                LabeledContent("Not readable", value: "\(vault.skippedItemCount)")
            }
            Button {
                Task { await vault.sync() }
            } label: {
                if vault.isSyncing {
                    HStack { ProgressView(); Text("Syncing…") }
                } else {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(vault.isSyncing)
            .accessibilityIdentifier("passwordsSyncNow")
            if let error = vault.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("passwordsSyncError")
            }
        } header: {
            Text("Sync")
        } footer: {
            Text(
                "Syncs on demand and when Zen comes back to the foreground, not on a timer. "
                    + (vault.skippedItemCount > 0
                        ? "Items encrypted with an organisation key cannot be read and are skipped."
                        : ""))
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        Section {
            Toggle(
                "Require Face ID",
                isOn: Binding(
                    get: { vault.configuration?.requiresBiometrics ?? true },
                    set: { vault.setRequiresBiometrics($0) })
            )
            .accessibilityIdentifier("passwordsBiometricsToggle")
            Button("Clear Cached Index") { vault.clearCache() }
                .accessibilityIdentifier("passwordsClearCache")
            Button("Forget Vault", role: .destructive) { isForgetConfirmed = true }
                .accessibilityIdentifier("passwordsForgetVault")
        } header: {
            Text("On this device")
        } footer: {
            Text(biometricsFooter)
        }
    }

    private var biometricsFooter: String {
        var context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error)
        context = LAContext()
        let base =
            "The cached index holds titles, usernames and site addresses — never passwords, which "
            + "are fetched for the one entry you act on."
        return available
            ? base + " Face ID is asked for before a password is revealed or filled."
            : base
                + " This device has no biometry enrolled, so the Face ID check passes through — "
                + "which is also why it can be exercised in a simulator."
    }

    // MARK: AutoFill

    @ViewBuilder
    private var autoFillSection: some View {
        Section {
            Text(
                "Separately from the vault above, Zen supports iOS Password AutoFill: tap a login "
                    + "field on a page and the key above the keyboard offers the accounts your "
                    + "password manager holds for that site. Whatever you have set as the AutoFill "
                    + "provider — iCloud Passwords, 1Password, Bitwarden — is what answers, and "
                    + "Zen never sees it.")
            .font(.callout)
        } header: {
            Text("iOS Password AutoFill")
        } footer: {
            Text(
                "This is the only route iOS gives a third-party browser into another app's vault. "
                    + "There is no browser-extension model on iOS — Firefox for iOS fills logins "
                    + "the same way. It works whether or not a vault is connected above.")
        }
    }

    @ViewBuilder
    private var autoFillPathSection: some View {
        Section {
            ForEach(Array(Self.autoFillPath.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(palette.accent.color)
                        .frame(width: 16, alignment: .trailing)
                    Text(step).font(.callout)
                }
            }
            Button {
                Haptics.shared.fire(.tabSelect)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Zen in iOS Settings", systemImage: "arrow.up.forward.app")
            }
            .accessibilityIdentifier("passwordsOpenSettingsButton")
        } header: {
            Text("Choose your AutoFill provider")
        } footer: {
            Text(
                "Written out rather than linked: iOS publishes no URL for the AutoFill pane, and "
                    + "the button can only open Zen's own settings page — go back once from there "
                    + "to reach Settings itself. The wording moved in iOS 18; on iOS 17 it is "
                    + "Settings → Passwords → Password Options.")
        }
    }

    @ViewBuilder
    private var storesSection: some View {
        Section {
            LabeledContent("Passkeys", value: "Handled by iOS")
            LabeledContent(
                "Passwords on this device",
                value: vault.isConfigured ? "Cached index only" : "None")
        } header: {
            Text("What Zen stores")
        } footer: {
            Text(
                "Passkeys work because WebKit implements WebAuthn: pages in Zen can call "
                    + "navigator.credentials and iOS puts up its own sheet — Zen neither sees nor "
                    + "stores the passkey. Vault credentials live in the keychain, device-only "
                    + "and never in a backup; the cached index is encrypted with a key that lives "
                    + "there too.")
        }
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
