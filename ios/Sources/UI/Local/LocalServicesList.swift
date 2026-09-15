//  LocalServicesList.swift
//  The Local section: the services you kept from a LAN scan, grouped by host.
//
//  History and Bookmarks are "places you have been" and "places you chose";
//  Local is "places that are *here*" — and on a home network that is the list
//  you actually use. It is the same list wherever it appears: the History
//  sheet's third segment, its own sheet from the bar, and the omnibox's
//  suggestions all read `LocalServiceStore`.

import SwiftUI

/// The reusable body. `HistorySheet` embeds it as a segment; `LocalSectionSheet`
/// wraps it in its own navigation stack for the bar's Local button.
struct LocalServicesList: View {
    @ObservedObject var state: BrowserState
    @ObservedObject var store: LocalServiceStore
    var query: String = ""
    /// Called after a service is opened, so a sheet can dismiss itself.
    var onOpen: () -> Void = {}

    @Environment(\.zenPalette) private var palette
    @State private var editing: LocalService?

    private var groups: [(host: String, services: [LocalService])] {
        let all = store.byHost
        guard !query.isEmpty else { return all }
        let needle = query.lowercased()
        return
            all
            .map { group in
                (
                    host: group.host,
                    services: group.services.filter {
                        $0.alias.lowercased().contains(needle)
                            || $0.host.lowercased().contains(needle)
                            || ($0.hostname?.lowercased().contains(needle) ?? false)
                            || $0.url.absoluteString.lowercased().contains(needle)
                    }
                )
            }
            .filter { !$0.services.isEmpty }
    }

    var body: some View {
        List {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label(
                        store.isEmpty ? "No local services yet" : "No matches",
                        systemImage: "network")
                } description: {
                    if store.isEmpty {
                        Text(
                            "Scan your home network from Settings › Local network, then "
                                + "import what you want to keep.")
                    }
                } actions: {
                    if store.isEmpty {
                        Button("Open Settings") {
                            onOpen()
                            state.isSettingsPresented = true
                        }
                    }
                }
            }
            ForEach(groups, id: \.host) { group in
                Section(group.host) {
                    ForEach(group.services) { service in
                        row(service)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $editing) { service in
            LocalServiceEditor(store: store, service: service)
                .environment(\.zenPalette, palette)
        }
    }

    private func row(_ service: LocalService) -> some View {
        Button {
            open(service.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: service.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.accent.color)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.alias)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(service.addressLabel)
                        Text("·")
                        Text(service.lastSeen, style: .relative)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if service.certificateChangedAt != nil {
                    // A changed certificate on a host you trusted is the one
                    // finding worth interrupting for (#00889 draws the same
                    // line); it is a flag, not a silent update.
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(ZenTokens.warningColor.color)
                        .accessibilityLabel("Certificate changed")
                }
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityIdentifier("localService-\(service.alias)")
        .contextMenu {
            Button { editing = service } label: {
                Label("Edit alias", systemImage: "pencil")
            }
            Button {
                Haptics.shared.fire(.glanceOpen)
                state.openGlance(url: service.url)
                onOpen()
            } label: {
                Label("Open in Glance", systemImage: "rectangle.on.rectangle.angled")
            }
            Button {
                UIPasteboard.general.url = service.url
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                store.forget(service)
            } label: {
                Label("Forget", systemImage: "trash")
            }
        }
        .swipeActions {
            Button(role: .destructive) { store.forget(service) } label: {
                Label("Forget", systemImage: "trash")
            }
            Button { editing = service } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.indigo)
        }
    }

    /// Opens in the current space, as History and Bookmarks do.
    private func open(_ url: URL) {
        Haptics.shared.fire(.urlCommit)
        if let tabID = state.activeTabID {
            state.updateTab(tabID) { tab in
                tab.url = url
                tab.title = ""
                tab.scrollY = 0
                tab.loadFailure = nil
            }
        } else {
            state.newTab(url: url)
        }
        onOpen()
    }
}

/// The bar's Local button, as its own sheet.
struct LocalSectionSheet: View {
    @ObservedObject var state: BrowserState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette
    @State private var query = ""

    var body: some View {
        NavigationStack {
            LocalServicesList(
                state: state, store: state.localServices, query: query,
                onOpen: { dismiss() }
            )
            .searchable(text: $query, prompt: "Search local services")
            .navigationTitle("Local")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        dismiss()
                        state.isSettingsPresented = true
                    } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    .accessibilityLabel("Scan network")
                }
            }
        }
        .tint(palette.accent.color)
    }
}

/// Rename, annotate and inspect one service.
struct LocalServiceEditor: View {
    @ObservedObject var store: LocalServiceStore
    let service: LocalService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette
    @State private var alias: String = ""
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Alias", text: $alias)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("localAliasField")
                } header: {
                    Text("Alias")
                } footer: {
                    Text(
                        "Typing this word on its own in the address bar goes "
                            + "straight here.")
                }

                Section("Address") {
                    LabeledContent("URL", value: service.url.absoluteString)
                    LabeledContent("Host", value: service.host)
                    if let hostname = service.hostname {
                        LabeledContent("Name", value: hostname)
                    }
                    LabeledContent("Port", value: "\(service.port)")
                    LabeledContent("Service", value: service.kind.name)
                    LabeledContent("Last seen", value: service.lastSeen.formatted())
                }

                if let certificate = service.certificate {
                    Section {
                        LabeledContent("Subject", value: certificate.subject)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SHA-256")
                            Text(certificate.displayFingerprint)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let expires = certificate.expires {
                            LabeledContent("Expires", value: expires.formatted(date: .abbreviated, time: .omitted))
                        }
                        if service.certificateChangedAt != nil {
                            Button {
                                store.acknowledgeCertificate(service)
                            } label: {
                                Label("Acknowledge change", systemImage: "checkmark.shield")
                            }
                        }
                    } header: {
                        Text("Certificate")
                    } footer: {
                        Text(
                            service.certificateChangedAt != nil
                                ? "This host is serving a different certificate than the one "
                                    + "imported. Check the fingerprint against the box itself "
                                    + "before trusting it again."
                                : "Captured during the scan without trusting it. Compare it "
                                    + "with `openssl x509 -fingerprint -sha256` on the device.")
                    }
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Button(role: .destructive) {
                        store.forget(service)
                        dismiss()
                    } label: {
                        Label("Forget this service", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(service.alias)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.rename(service, to: alias)
                        store.setNotes(notes, for: service)
                        dismiss()
                    }
                }
            }
            .onAppear {
                alias = service.alias
                notes = service.notes
            }
        }
        .tint(palette.accent.color)
    }
}
