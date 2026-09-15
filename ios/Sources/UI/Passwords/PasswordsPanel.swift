//  PasswordsPanel.swift
//  The vault panel: which of your logins belong to this page, and one tap to
//  use them (#008AD).
//
//  Reachable two ways, both of which are the same action from the bar's one
//  vocabulary (`BarAction.passwords`): as a button someone puts in a slot, and
//  from the omnibox's overflow menu, which is built from the layout's overflow
//  slots. Adding it to the library was therefore the whole of the wiring —
//  see `BarAction.swift`.
//
//  ## Why the page's matches come first and search comes second
//
//  Ninety-nine times in a hundred the answer is "the login for this site", and
//  a panel that opens on a search field makes you type to reach something it
//  already knew. So it opens on the matches, sorted best-first by
//  `DomainMatching` — exact host above same-domain — and search is there for
//  the hundredth time, when the entry is filed under a name that does not look
//  like the site.
//
//  ## What it does and does not hold
//
//  Rows come from the sealed index, which has no passwords in it. A secret is
//  fetched for the one row that is acted on, used, and dropped: nothing here
//  keeps a `VaultLogin` with a password in `@State`. The revealed password is
//  held for as long as the disclosure is open and cleared on dismiss, which is
//  the one deliberate exception and is visible in `revealed`.

import Combine
import SwiftUI
import WebKit

struct PasswordsPanel: View {
    @ObservedObject var state: BrowserState
    @ObservedObject var vault: PasswordVaultService
    let pool: WebViewPool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette

    @State private var query = ""
    /// Ids whose password is currently on screen. Cleared on dismiss.
    @State private var revealed: [String: VaultLogin] = [:]
    @State private var busyID: String?
    @State private var banner: String?
    @State private var failure: String?
    /// Ticks once a second so the one-time code and its countdown stay true.
    @State private var now = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Passwords")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await vault.sync() }
                        } label: {
                            if vault.isSyncing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(vault.isSyncing || !vault.isConfigured)
                        .accessibilityLabel("Sync vault")
                    }
                }
        }
        .tint(palette.accent.color)
        .accessibilityIdentifier("passwordsPanel")
        .onReceive(clock) { now = $0 }
        .onDisappear { revealed.removeAll() }
        .alert(
            "Vault", isPresented: .constant(failure != nil),
            actions: { Button("OK") { failure = nil } },
            message: { Text(failure ?? "") })
    }

    // MARK: Layers
    //
    // Split into properties for the same reason `SettingsSheet` is: one `List`
    // with this many sections, bindings and closures is past what the type
    // checker will solve, and the error it gives names no cause.

    @ViewBuilder
    private var content: some View {
        if !vault.isConfigured {
            unconfigured
        } else {
            List {
                if !query.isEmpty {
                    searchResults
                } else {
                    pageMatches
                    everythingElse
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Search the vault")
            .overlay(alignment: .bottom) { bannerView }
            .refreshable { await vault.sync() }
        }
    }

    private var unconfigured: some View {
        ContentUnavailableView {
            Label("No vault set up", systemImage: "key.slash")
        } description: {
            Text(
                "Connect 1Password Connect or Vaultwarden in Settings → Passwords to see logins "
                    + "for this page here.")
        } actions: {
            Button("Open Settings") {
                dismiss()
                state.isSettingsPresented = true
            }
            .accessibilityIdentifier("passwordsPanelSetUpButton")
        }
        .accessibilityIdentifier("passwordsPanelEmpty")
    }

    @ViewBuilder
    private var pageMatches: some View {
        let matches = pageURL.map { vault.matchingEntries(for: $0) } ?? []
        Section {
            if matches.isEmpty {
                Text(
                    vault.entries.isEmpty
                        ? "Nothing synced yet. Pull to sync."
                        : "No login in the vault matches this page.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(matches) { row($0) }
            }
        } header: {
            Text(pageURL?.host.map { "For \($0)" } ?? "For this page")
        } footer: {
            if !matches.isEmpty {
                Text("Tap to fill. Touch and hold for the password and the one-time code.")
            }
        }
    }

    @ViewBuilder
    private var everythingElse: some View {
        let matchedIDs = Set((pageURL.map { vault.matchingEntries(for: $0) } ?? []).map(\.id))
        let rest = vault.entries.filter { !matchedIDs.contains($0.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if !rest.isEmpty {
            Section("All logins") {
                ForEach(rest.prefix(50)) { row($0) }
                if rest.count > 50 {
                    Text("\(rest.count - 50) more — use search.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = vault.search(query)
        Section("Results") {
            if results.isEmpty {
                Text("Nothing in the vault matches “\(query)”.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results) { row($0) }
            }
        }
    }

    // MARK: A row

    @ViewBuilder
    private func row(_ entry: VaultIndexEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await fill(entry) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.badge.key.fill")
                        .foregroundStyle(palette.accent.color)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.body)
                        if let subtitle = subtitle(for: entry) {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if busyID == entry.id {
                        ProgressView()
                    } else if entry.hasTOTP {
                        Image(systemName: "123.rectangle")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Has a one-time code")
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("passwordRow-\(entry.id)")

            if let login = revealed[entry.id] {
                revealedDetail(entry: entry, login: login)
            }
        }
        .contextMenu { menu(for: entry) }
    }

    @ViewBuilder
    private func revealedDetail(entry: VaultIndexEntry, login: VaultLogin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let password = login.password {
                LabeledContent("Password") {
                    Text(password)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if let totp = login.totp, let configuration = try? TOTPGenerator.configuration(from: totp) {
                Button {
                    UIPasteboard.general.string = TOTPGenerator.code(for: configuration, at: now)
                    Haptics.shared.fire(.tabSelect)
                    show("One-time code copied")
                } label: {
                    HStack {
                        Text("One-time code")
                        Spacer()
                        Text(spaced(TOTPGenerator.code(for: configuration, at: now)))
                            .font(.system(.footnote, design: .monospaced))
                            .monospacedDigit()
                        // The countdown is what tells you whether to wait for
                        // the next one rather than type a code about to expire.
                        Text("\(TOTPGenerator.secondsRemaining(for: configuration, at: now))s")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityIdentifier("totpRow-\(entry.id)")
            }
        }
        .padding(.top, 8)
        .padding(.leading, 34)
        .font(.footnote)
    }

    @ViewBuilder
    private func menu(for entry: VaultIndexEntry) -> some View {
        Button { Task { await fill(entry) } } label: {
            Label("Fill", systemImage: "arrow.down.doc")
        }
        if let username = entry.username, !username.isEmpty {
            Button {
                UIPasteboard.general.string = username
                show("Username copied")
            } label: {
                Label("Copy Username", systemImage: "doc.on.doc")
            }
        }
        Button { Task { await reveal(entry) } } label: {
            Label(
                revealed[entry.id] == nil ? "Reveal Password" : "Hide Password",
                systemImage: revealed[entry.id] == nil ? "eye" : "eye.slash")
        }
        Button { Task { await copyPassword(entry) } } label: {
            Label("Copy Password", systemImage: "key")
        }
        if entry.hasTOTP {
            Button { Task { await copyCode(entry) } } label: {
                Label("Copy One-Time Code", systemImage: "123.rectangle")
            }
        }
    }

    // MARK: Actions

    private var pageURL: URL? {
        guard let tabID = state.activeTabID,
            let tab = state.tabs.first(where: { $0.id == tabID }),
            !tab.isNewTabPage
        else { return nil }
        return tab.url
    }

    private func subtitle(for entry: VaultIndexEntry) -> String? {
        let parts = [entry.username, entry.vaultName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Fetch the secret (behind Face ID) and put it in the page.
    private func fill(_ entry: VaultIndexEntry) async {
        guard let tabID = state.activeTabID, let webView = pool.existing(for: tabID) else {
            failure = "There is no page to fill."
            return
        }
        busyID = entry.id
        defer { busyID = nil }
        do {
            let login = try await vault.reveal(
                VaultItemID(entry.id), reason: "Fill your password for \(entry.title)")
            guard let password = login.password, !password.isEmpty else {
                failure = "That entry has no password stored."
                return
            }
            let script = LoginFormFill.fillScript(username: login.username, password: password)
            let raw = try await webView.evaluateJavaScript(script) as? String
            let result = try JSONDecoder().decode(
                LoginFormFillResult.self, from: Data((raw ?? "").utf8))
            guard result.filled else {
                failure =
                    "Zen could not find a login form on this page"
                    + (result.reason.map { " (\($0))" } ?? "") + "."
                return
            }
            Haptics.shared.fire(.tabSelect)
            dismiss()
        } catch is CancellationError {
            // Face ID cancelled; say nothing.
        } catch let error as VaultError where error == .cancelled {
            // Ditto — a cancelled unlock is a decision, not a fault.
        } catch {
            failure = PasswordVaultService.describe(error)
        }
    }

    private func reveal(_ entry: VaultIndexEntry) async {
        if revealed[entry.id] != nil {
            revealed[entry.id] = nil
            return
        }
        busyID = entry.id
        defer { busyID = nil }
        do {
            revealed[entry.id] = try await vault.reveal(
                VaultItemID(entry.id), reason: "Show your password for \(entry.title)")
        } catch let error as VaultError where error == .cancelled {
        } catch {
            failure = PasswordVaultService.describe(error)
        }
    }

    private func copyPassword(_ entry: VaultIndexEntry) async {
        do {
            let login = try await vault.reveal(
                VaultItemID(entry.id), reason: "Copy your password for \(entry.title)")
            guard let password = login.password else {
                failure = "That entry has no password stored."
                return
            }
            UIPasteboard.general.string = password
            Haptics.shared.fire(.tabSelect)
            show("Password copied")
        } catch let error as VaultError where error == .cancelled {
        } catch {
            failure = PasswordVaultService.describe(error)
        }
    }

    private func copyCode(_ entry: VaultIndexEntry) async {
        do {
            let login = try await vault.reveal(
                VaultItemID(entry.id), reason: "Copy the one-time code for \(entry.title)")
            guard let totp = login.totp else {
                failure = "That entry has no one-time code."
                return
            }
            let configuration = try TOTPGenerator.configuration(from: totp)
            UIPasteboard.general.string = TOTPGenerator.code(for: configuration)
            Haptics.shared.fire(.tabSelect)
            show("One-time code copied")
        } catch let error as VaultError where error == .cancelled {
        } catch {
            failure = PasswordVaultService.describe(error)
        }
    }

    // MARK: Chrome

    /// Six digits are read in two groups of three; the space is not decoration.
    private func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }

    private func show(_ message: String) {
        banner = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if banner == message { banner = nil }
        }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner {
            Text(banner)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 18)
                .transition(.opacity)
                .accessibilityIdentifier("passwordsBanner")
        }
    }
}
