//  SavePasswordSheet.swift
//  "Save this to your vault?" after a login form is submitted (#008AD).
//
//  The prompt only exists because the alternative is worse: a vault you have to
//  remember to add things to is a vault that quietly goes out of date, and the
//  first time that matters is the time you are locked out.
//
//  Three decisions worth stating, because each is a case where the obvious
//  behaviour is wrong:
//
//   - **Registration forms are skipped entirely.** Two password fields means a
//     sign-up, and the password there has not been accepted by the site yet.
//     Saving it and then having the signup rejected for "password too short"
//     leaves a wrong credential in the vault that looks right. The filter is in
//     `PasswordVaultService.noteSubmittedCredential`.
//   - **Update beats create when the username matches.** Two entries for one
//     site with one working password is the state everybody's vault drifts
//     into; matching on site *and* username is what avoids it.
//   - **Nothing is saved silently.** The sheet shows the password, masked but
//     revealable, because a credential saved without being seen is a credential
//     nobody can correct.

import SwiftUI

struct SavePasswordSheet: View {
    let credential: SubmittedCredential
    /// The entry this would overwrite, when the service found one.
    let existing: VaultLogin?
    @ObservedObject var vault: PasswordVaultService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette

    @State private var title: String
    @State private var username: String
    @State private var password: String
    @State private var isPasswordVisible = false
    @State private var isSaving = false
    @State private var failure: String?

    init(
        credential: SubmittedCredential, existing: VaultLogin?, vault: PasswordVaultService
    ) {
        self.credential = credential
        self.existing = existing
        self.vault = vault
        // Seeded from the page, then editable: a page title is often "Sign in
        // — Example" and nobody wants that as the vault entry's name.
        _title = State(initialValue: existing?.title ?? Self.suggestedTitle(for: credential))
        _username = State(initialValue: credential.username ?? existing?.username ?? "")
        _password = State(initialValue: credential.password)
    }

    private var isUpdate: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $title)
                        .accessibilityIdentifier("savePasswordTitle")
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("savePasswordUsername")
                    passwordField
                } header: {
                    Text(isUpdate ? "Update this login" : "New login")
                } footer: {
                    Text(credential.url.host ?? credential.url.absoluteString)
                }

                Section {
                    Button(isUpdate ? "Update in Vault" : "Save to Vault") {
                        Task { await save() }
                    }
                    .disabled(isSaving || password.isEmpty)
                    .accessibilityIdentifier("savePasswordConfirm")
                    Button("Not Now", role: .cancel) { dismiss() }
                } footer: {
                    Text(footerText)
                }
            }
            .navigationTitle(isUpdate ? "Update Password" : "Save Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay {
                if isSaving { ProgressView().controlSize(.large) }
            }
        }
        .tint(palette.accent.color)
        .accessibilityIdentifier("savePasswordSheet")
        .alert(
            "Vault", isPresented: .constant(failure != nil),
            actions: { Button("OK") { failure = nil } },
            message: { Text(failure ?? "") })
    }

    @ViewBuilder
    private var passwordField: some View {
        HStack {
            if isPasswordVisible {
                TextField("Password", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            } else {
                SecureField("Password", text: $password)
            }
            Button {
                isPasswordVisible.toggle()
            } label: {
                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
        }
        .accessibilityIdentifier("savePasswordPassword")
    }

    private var footerText: String {
        guard let kind = vault.configuration?.kind else {
            return "No vault is configured."
        }
        return isUpdate
            ? "Replaces the username and password on the existing \(kind.displayName) entry."
            : "Creates a new login in \(kind.displayName)."
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let draft = VaultLoginDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username,
            password: password,
            // The origin, not the full URL: a vault entry pinned to
            // `/login?next=%2Faccount` matches nothing the next time.
            uri: Self.origin(of: credential.url))
        do {
            if let existing {
                _ = try await vault.updateLogin(existing.id, with: draft)
            } else {
                _ = try await vault.createLogin(draft)
            }
            Haptics.shared.fire(.tabSelect)
            dismiss()
        } catch {
            failure = PasswordVaultService.describe(error)
        }
    }

    // MARK: Suggestions

    static func suggestedTitle(for credential: SubmittedCredential) -> String {
        // The registrable domain reads better in a vault list than either the
        // page title ("Sign in — Example, the best example") or the full host.
        if let domain = DomainMatching.registrableDomain(ofHost: credential.url.host ?? "") {
            return domain
        }
        if let host = credential.url.host { return host }
        return credential.title
    }

    static func origin(of url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.string ?? url.absoluteString
    }
}
