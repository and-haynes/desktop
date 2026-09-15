//  VaultSetUpSheet.swift
//  Connecting a vault, and refusing to pretend it worked (#008AD).
//
//  The whole design of this sheet is one decision: **"Save" tests the
//  connection first and only saves if it answered.** Storing a server URL and a
//  token that have never been tried produces a settings screen that looks
//  configured and a panel that is permanently empty, and the error surfaces
//  somewhere far from the mistake. Here, the failure lands next to the field
//  that caused it, with the server's own words.
//
//  The two providers need different things, which is why the form is a switch
//  on the kind rather than a union of every field:
//
//   - **1Password Connect** — a server URL and a bearer token. No user, no
//     password, no crypto on our side: Connect holds the unlocked vault and
//     the token is the whole of the authorisation.
//   - **Bitwarden / Vaultwarden** — a server URL, the account email and the
//     master password. The password never leaves the device: it becomes a
//     master key by PBKDF2 and only a derived hash is sent. That is worth
//     saying on the screen, because "type your master password into a browser"
//     is a sentence that should make anybody hesitate.

import SwiftUI

struct VaultSetUpSheet: View {
    @ObservedObject var vault: PasswordVaultService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette

    @State private var kind: VaultProviderKind = .bitwarden
    @State private var serverURL = ""
    @State private var email = ""
    @State private var masterPassword = ""
    @State private var connectToken = ""
    @State private var allowsSelfSignedTLS = false
    @State private var isTesting = false
    @State private var result: String?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                providerSection
                credentialsSection
                transportSection
                actionSection
            }
            .navigationTitle("Connect a Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(palette.accent.color)
        .accessibilityIdentifier("vaultSetUpSheet")
        .onAppear(perform: seedFromExisting)
        .alert(
            "Could not connect", isPresented: .constant(failure != nil),
            actions: { Button("OK") { failure = nil } },
            message: { Text(failure ?? "") })
    }

    // MARK: Sections

    @ViewBuilder
    private var providerSection: some View {
        Section {
            Picker("Provider", selection: $kind) {
                ForEach(VaultProviderKind.allCases) { kind in
                    Label(kind.displayName, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("vaultProviderPicker")
        } header: {
            Text("Provider")
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        Section {
            TextField(serverPlaceholder, text: $serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("vaultServerField")
            switch kind {
            case .onePasswordConnect:
                SecureField("Connect token", text: $connectToken)
                    .accessibilityIdentifier("vaultTokenField")
            case .bitwarden:
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .accessibilityIdentifier("vaultEmailField")
                SecureField("Master password", text: $masterPassword)
                    .accessibilityIdentifier("vaultMasterPasswordField")
            }
        } header: {
            Text("Server")
        } footer: {
            Text(credentialsFooter)
        }
    }

    private var serverPlaceholder: String {
        switch kind {
        case .onePasswordConnect: return "https://connect.lan:8080"
        case .bitwarden: return "https://vault.lan"
        }
    }

    private var credentialsFooter: String {
        switch kind {
        case .onePasswordConnect:
            return
                "The token is a bearer credential for every vault it was issued against — scope it "
                + "narrowly when you mint it. It is kept in the keychain, device-only."
        case .bitwarden:
            return
                "The master password never leaves this device: it is turned into a key with "
                + "PBKDF2 and only a derived hash is sent, which is how every Bitwarden client "
                + "works. Vaultwarden counts as Bitwarden here."
        }
    }

    @ViewBuilder
    private var transportSection: some View {
        Section {
            Toggle("Allow a self-signed certificate", isOn: $allowsSelfSignedTLS)
                .accessibilityIdentifier("vaultSelfSignedToggle")
        } footer: {
            Text(
                "Off unless you need it. The homelab's own certificate authority is not one iOS "
                    + "trusts, so a server on vault.lan will need this — but it also means Zen "
                    + "stops checking who it is talking to on that host, so turn it on only for a "
                    + "server on your own network.")
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            Button {
                Task { await testAndSave() }
            } label: {
                if isTesting {
                    HStack { ProgressView(); Text("Connecting…") }
                } else {
                    Text("Test and Save")
                }
            }
            .disabled(isTesting || !isComplete)
            .accessibilityIdentifier("vaultTestAndSave")
            if let result {
                Text(result)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("vaultSetUpResult")
            }
        } footer: {
            Text(
                "The connection is tried before anything is saved — a stored server that has "
                    + "never answered is a settings screen that lies to you.")
        }
    }

    // MARK: Behaviour

    private var isComplete: Bool {
        guard !serverURL.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .onePasswordConnect: return !connectToken.isEmpty
        case .bitwarden: return !email.isEmpty && !masterPassword.isEmpty
        }
    }

    private func seedFromExisting() {
        guard let configuration = vault.configuration else { return }
        kind = configuration.kind
        serverURL = configuration.serverURL
        email = configuration.accountEmail ?? ""
        allowsSelfSignedTLS = configuration.allowsSelfSignedTLS
        // Secrets are deliberately not seeded: they are in the keychain, and
        // reading them back into a text field to redisplay them would put a
        // master password in a SwiftUI state box for no gain.
    }

    private func testAndSave() async {
        isTesting = true
        defer { isTesting = false }
        result = nil

        let configuration = VaultConfiguration(
            kind: kind,
            serverURL: serverURL.trimmingCharacters(in: .whitespaces),
            accountEmail: kind == .bitwarden ? email : nil,
            allowsSelfSignedTLS: allowsSelfSignedTLS,
            requiresBiometrics: vault.configuration?.requiresBiometrics ?? true)
        let credentials = VaultCredentials(
            connectToken: kind == .onePasswordConnect ? connectToken : nil,
            masterPassword: kind == .bitwarden ? masterPassword : nil)

        do {
            let vaults = try await vault.testConnection(configuration, credentials: credentials)
            guard vault.configure(configuration, credentials: credentials) else {
                // `configure` has already put the reason in `lastError`; show
                // it here rather than dismissing onto a screen that would look
                // connected.
                failure = vault.lastError
                return
            }
            result = "Connected. \(vaults.count) vault\(vaults.count == 1 ? "" : "s") visible."
            await vault.sync()
            dismiss()
        } catch {
            failure = PasswordVaultService.describe(error)
        }
    }
}
