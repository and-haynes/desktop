//  SyncSettingsView.swift
//  Settings → Sync.
//
//  Zen desktop puts the engine switches next to the account; so does this. The
//  screen has one job beyond the switches: to be honest about state. "Sync"
//  that silently stopped working three weeks ago is worse than no sync, so the
//  status row always says what happened and when, including the boring answers
//  ("Up to date", a timestamp).

import SwiftUI

struct SyncSettingsSection: View {
    @ObservedObject var sync: SyncService
    @Environment(\.zenPalette) private var palette

    var body: some View {
        Section {
            if sync.isSignedIn {
                signedInRows
            } else {
                signInRow
            }
        } header: {
            Text("Sync")
        } footer: {
            Text(footerText)
        }
    }

    // MARK: Signed out

    private var signInRow: some View {
        Button {
            Haptics.shared.fire(.tabSelect)
            Task { await sync.signIn() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                Text("Sign in to a Mozilla account")
                Spacer()
                if sync.status.isBusy { ProgressView() }
            }
        }
        .accessibilityIdentifier("syncSignInButton")
        .disabled(sync.status.isBusy)
        .overlay(alignment: .bottom) {
            if case .failed(let message) = sync.status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: 18)
            }
        }
    }

    // MARK: Signed in

    @ViewBuilder
    private var signedInRows: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(palette.accent.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(sync.account?.label ?? "Mozilla account")
                if let email = sync.account?.email, email != sync.account?.displayName {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .accessibilityIdentifier("syncAccountRow")

        statusRow

        Toggle("Sync this device", isOn: $sync.preferences.enabled)
            .accessibilityIdentifier("syncEnabledToggle")

        NavigationLink {
            SyncDetailView(sync: sync)
        } label: {
            Label("Sync options", systemImage: "slider.horizontal.3")
        }
        .accessibilityIdentifier("syncOptionsLink")

        Button {
            Haptics.shared.fire(.tabSelect)
            sync.syncNow(reason: .manual)
        } label: {
            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(sync.status.isBusy || !sync.preferences.enabled)
        .accessibilityIdentifier("syncNowButton")
    }

    private var statusRow: some View {
        HStack {
            Label {
                Text(sync.status.summary)
            } icon: {
                Image(systemName: sync.status.symbol)
                    .foregroundStyle(statusTint)
                    .symbolEffect(
                        .pulse, options: .repeating, isActive: sync.status.isBusy)
            }
            Spacer()
            if let last = sync.lastSyncedAt, !sync.status.isBusy {
                Text(last, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("syncStatusRow")
    }

    private var statusTint: Color {
        switch sync.status {
        case .failed: return .red
        case .backingOff: return .orange
        case .idle: return .green
        default: return palette.accent.color
        }
    }

    private var footerText: String {
        if sync.isSignedIn {
            return
                "Spaces, pinned tabs and essentials sync with Zen on the desktop through "
                + "its own spaces engine, so both ends see the same spaces. Everything is "
                + "encrypted on this device before it is uploaded; Mozilla's servers store "
                + "ciphertext and never hold the key."
        }
        return
            "Sign in with the same Mozilla account Zen uses on the desktop. Sign-in opens "
            + "in Safari, so your password is never typed into this app. The consent screen "
            + "says Firefox: Zen for iOS signs in as an unofficial client using Firefox for "
            + "iOS's public OAuth client id, because Mozilla does not issue ids to "
            + "third-party browsers."
    }
}

/// The second page: engine switches, device name, and the two destructive
/// buttons, which are deliberately not one tap from the main screen.
struct SyncDetailView: View {
    @ObservedObject var sync: SyncService
    @Environment(\.dismiss) private var dismiss
    @State private var deviceName: String = ""
    @State private var isConfirmingSignOut = false

    var body: some View {
        Form {
            Section {
                Toggle("Spaces and pinned tabs", isOn: $sync.preferences.syncSpaces)
                    .accessibilityIdentifier("syncSpacesToggle")
                if sync.preferences.syncSpaces {
                    Toggle("Also sync ordinary tabs", isOn: $sync.preferences.syncNormalTabs)
                        .accessibilityIdentifier("syncNormalTabsToggle")
                        .padding(.leading, 16)
                }
                Toggle("Bookmarks", isOn: $sync.preferences.syncBookmarks)
                Toggle("Open tabs", isOn: $sync.preferences.syncTabs)
                Toggle("History", isOn: $sync.preferences.syncHistory)
            } header: {
                Text("What to sync")
            } footer: {
                Text(
                    "\"Also sync ordinary tabs\" is Zen's own zen.spaces-sync.normal-tabs, "
                        + "off on the desktop too — the spaces engine otherwise carries only "
                        + "pinned and essential tabs, which are the ones meant to be the same "
                        + "everywhere. Bookmarks sync as a flat list into Mobile Bookmarks; "
                        + "folders made on the desktop stay there and their contents appear "
                        + "here unfiled.")
            }

            Section {
                TextField(sync.effectiveDeviceName, text: $deviceName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("syncDeviceNameField")
                    .onSubmit { sync.preferences.deviceName = deviceName }
            } header: {
                Text("Device name")
            } footer: {
                Text("How this phone appears in the account's device list and on other devices' synced-tab lists.")
            }

            Section {
                Button("Reset sync data on this device") {
                    sync.forgetSyncState()
                }
                .accessibilityIdentifier("syncResetButton")
                Button("Sign out", role: .destructive) {
                    isConfirmingSignOut = true
                }
                .accessibilityIdentifier("syncSignOutButton")
            } footer: {
                Text(
                    "Resetting forgets what this device thinks the server holds and makes the "
                        + "next sync a full one; nothing is deleted from the account. Signing "
                        + "out removes the account's keys from this phone — your spaces, tabs "
                        + "and bookmarks stay on it, and stay in the account.")
            }
        }
        .navigationTitle("Sync options")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { deviceName = sync.preferences.deviceName }
        .onChange(of: deviceName) { _, value in sync.preferences.deviceName = value }
        .confirmationDialog(
            "Sign out of \(sync.account?.label ?? "this account")?",
            isPresented: $isConfirmingSignOut, titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                Task {
                    await sync.signOut()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
