//  ExtensionsSettingsView.swift
//  Settings → Extensions: what is installed, what it may do, and how to add
//  more (#008B8).
//
//  Three things this screen has to be honest about, none of which are Zen's
//  doing and all of which are confusing if left unsaid:
//
//   1. **iOS 18.4.** WebKit's `WKWebExtension` arrived in that release. Below
//      it the screen still lists and removes what is installed — the records
//      are plain JSON — but nothing loads, and it says so at the top rather
//      than showing a list of extensions that quietly do nothing.
//   2. **Safari's App Store extensions are Safari's.** They are distributed as
//      app extensions bound to Safari, and no third-party browser can load
//      one. What *can* be loaded is the same thing Firefox and Chrome load:
//      the WebExtension package itself.
//   3. **A space is a boundary.** Each space has its own controller, so an
//      extension's storage does not cross between them.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - The Settings row

struct ExtensionsSettingsSection: View {
    @ObservedObject var host: ExtensionHost
    @ObservedObject var state: BrowserState

    var body: some View {
        Section {
            NavigationLink {
                ExtensionsSettingsView(host: host, state: state)
            } label: {
                HStack {
                    Label("Extensions", systemImage: "puzzlepiece.extension")
                    Spacer()
                    Text(count)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("extensionsSettingsLink")
        } footer: {
            Text(
                ExtensionHost.isSupported
                    ? "Firefox and Chrome extension packages, loaded by WebKit. Content "
                        + "scripts, declarativeNetRequest, storage and the tabs API work; "
                        + "Firefox-only APIs do not."
                    : ExtensionHost.requirementNote)
        }
    }

    private var count: String {
        guard ExtensionHost.isSupported else { return "iOS 18.4" }
        let installed = host.store.extensions.count
        guard installed > 0 else { return "None" }
        let enabled = host.store.enabledExtensions.count
        return enabled == installed ? "\(installed)" : "\(enabled) of \(installed)"
    }
}

// MARK: - The screen

struct ExtensionsSettingsView: View {
    @ObservedObject var host: ExtensionHost
    @ObservedObject var state: BrowserState
    @Environment(\.zenPalette) private var palette

    @State private var isImporting = false
    @State private var linkText = ""
    @State private var isResolving = false
    @State private var prepared: PreparedExtension?
    /// The second built-in fixture, offered as soon as the first is decided —
    /// SwiftUI presents one sheet at a time, and two `Install` sheets racing
    /// each other means the second silently never appears.
    @State private var pendingFixtures: [PreparedExtension] = []
    @State private var failure: String?

    private var store: ExtensionStore { host.store }

    var body: some View {
        Form {
            if !ExtensionHost.isSupported { requirementSection }
            if !store.extensions.isEmpty { installedSection }
            addSection
            linkSection
            // Only for the UI test runner (#008DB): these paint a banner across
            // every page, and a real person has no reason to want that.
            if ExtensionStore.allowsBundledFixtures { fixturesSection }
            safariSection
        }
        .navigationTitle("Extensions")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("extensionsSettingsView")
        .fileImporter(
            isPresented: $isImporting,
            // `.item` rather than a precise list: an .xpi resolves to
            // `public.data` unless some app on the device exported a UTI for
            // it, and a picker that refuses the file somebody just downloaded
            // is worse than one that accepts a PDF and says no afterwards.
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(item: $prepared) { candidate in
            ExtensionInstallSheet(prepared: candidate, host: host)
                .environment(\.zenPalette, palette)
        }
        .onChange(of: prepared == nil) { _, dismissed in
            guard dismissed, !pendingFixtures.isEmpty else { return }
            let next = pendingFixtures.removeFirst()
            // A beat, or SwiftUI drops the second presentation on the floor
            // while the first sheet is still animating out.
            Task {
                // Long enough for the first sheet's dismissal to finish. A
                // presentation requested while one is still animating out is
                // dropped silently, and 450ms was not always enough on a cold
                // launch.
                try? await Task.sleep(for: .milliseconds(800))
                prepared = next
            }
        }
        .alert(
            "Could not read that", isPresented: .constant(failure != nil), presenting: failure
        ) { _ in
            Button("OK") { failure = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: Sections

    private var requirementSection: some View {
        Section {
            Label {
                Text(ExtensionHost.requirementNote)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            .font(.footnote)
        }
    }

    private var installedSection: some View {
        Section {
            ForEach(store.extensions) { record in
                NavigationLink {
                    ExtensionDetailView(record: record, host: host, state: state)
                        .environment(\.zenPalette, palette)
                } label: {
                    row(record)
                }
                .accessibilityIdentifier("extensionRow-\(record.id)")
            }
            .onDelete { offsets in
                for index in offsets { store.remove(store.extensions[index].id) }
                host.installedChanged()
            }
        } header: {
            Text("Installed")
        } footer: {
            Text(
                "Each space runs its own copy: an extension's settings and storage in Work "
                    + "are not the ones it has in Personal. Extensions are off in Focus, which "
                    + "is the whole point of Focus.")
        }
    }

    private func row(_ record: InstalledExtension) -> some View {
        HStack(spacing: 12) {
            ExtensionIconView(
                record: record,
                actionIcon: host.actions.first { $0.id == record.id }?.iconPNG,
                size: 30, directory: store.directory(for: record.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                HStack(spacing: 6) {
                    Text(record.isEnabled ? record.hostAccessSummary : "Off")
                        .foregroundStyle(.secondary)
                    if let error = host.loadErrors[record.id], record.isEnabled {
                        Text("· did not load")
                            .foregroundStyle(.red)
                            .accessibilityLabel("did not load: \(error)")
                    }
                }
                .font(.caption)
                if !record.compatibility.findings.isEmpty {
                    ExtensionCompatibilityBadge(report: record.compatibility)
                }
            }
            Spacer()
        }
    }

    private var addSection: some View {
        Section {
            Button {
                isImporting = true
            } label: {
                Label("Install from Files…", systemImage: "folder")
            }
            .accessibilityIdentifier("installFromFilesButton")
        } header: {
            Text("Add")
        } footer: {
            Text(
                "An .xpi (Firefox), a .crx or .zip (Chrome), or an unpacked folder with a "
                    + "manifest.json in it. You are shown what it asks for before anything is "
                    + "installed. Zen also appears in the Share sheet for those file types.")
        }
    }

    private var linkSection: some View {
        Section {
            HStack {
                TextField("addons.mozilla.org/…", text: $linkText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { resolveLink() }
                    .accessibilityIdentifier("extensionLinkField")
                if isResolving {
                    ProgressView()
                } else {
                    Button("Get") { resolveLink() }
                        .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("extensionLinkGetButton")
                }
            }
        } header: {
            Text("From a link")
        } footer: {
            Text(
                "Paste an addons.mozilla.org listing and Zen resolves it to the current "
                    + "version through Mozilla's public API, or paste a direct link to an "
                    + ".xpi, .crx or .zip.")
        }
    }

    private var fixturesSection: some View {
        Section {
            Button {
                installFixtures()
            } label: {
                Label("Install the two test extensions", systemImage: "testtube.2")
            }
            .accessibilityIdentifier("installFixturesButton")
        } header: {
            Text("Check it works")
        } footer: {
            Text(
                "Zen Badge puts a purple bar across every page from a content script, and "
                    + "Zen Blocker blocks anything whose address contains "
                    + "`zen-blocked-resource` with declarativeNetRequest. Between them they "
                    + "prove the two halves that matter, and they are the same packages the "
                    + "test suite uses.")
        }
    }

    private var safariSection: some View {
        Section {
            Label {
                Text(
                    "Safari extensions from the App Store cannot be loaded here. Apple ships "
                        + "them as app extensions bound to Safari, and no other browser — on "
                        + "any platform — is allowed to load one. A Safari extension's "
                        + "underlying WebExtension folder can be installed from Files like any "
                        + "other.")
            } icon: {
                Image(systemName: "lock.circle").foregroundStyle(.secondary)
            }
            .font(.footnote)
        } header: {
            Text("What will not work")
        }
    }

    // MARK: Behaviour

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            if url.hasDirectoryPath {
                prepared = try store.prepare(
                    directory: url, source: .file(name: url.lastPathComponent))
                return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            prepared = try store.prepare(
                archive: data, source: .file(name: url.lastPathComponent))
        } catch {
            failure = message(for: error)
        }
    }

    private func resolveLink() {
        let input = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isResolving else { return }
        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                let resolution = try await AddonsSource.resolve(input: input)
                let data = try await AddonsSource.download(resolution.downloadURL)
                prepared = try store.prepare(archive: data, source: resolution.source)
                linkText = ""
            } catch {
                failure = message(for: error)
            }
        }
    }

    private func installFixtures() {
        let candidates = store.prepareBundledFixtures()
        guard let first = candidates.first else {
            // Nothing prepared means either a broken build or — far more
            // likely — that both are already installed at this version.
            failure =
                store.extensions.isEmpty
                ? "The built-in extensions are missing from this build."
                : "Both test extensions are already installed."
            return
        }
        // One sheet at a time: the second is offered as soon as the first is
        // decided, which is what `pendingFixtures` below is for.
        pendingFixtures = Array(candidates.dropFirst())
        prepared = first
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - One extension

struct ExtensionDetailView: View {
    let record: InstalledExtension
    @ObservedObject var host: ExtensionHost
    @ObservedObject var state: BrowserState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette

    @State private var isRemoveConfirmed = false
    @State private var isUpdating = false
    @State private var failure: String?

    private var store: ExtensionStore { host.store }
    /// Always read back out of the store: the row's copy is a snapshot, and
    /// every toggle here writes through the store.
    private var live: InstalledExtension { store.record(id: record.id) ?? record }

    var body: some View {
        Form {
            headerSection
            statusSection
            if !permissions.isEmpty { permissionsSection }
            if !hostPatterns.isEmpty { hostsSection }
            thisSiteSection
            ExtensionCompatibilityView(report: live.compatibility)
            maintenanceSection
        }
        .navigationTitle(live.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("extensionDetail-\(record.id)")
        .alert("Could not update", isPresented: .constant(failure != nil), presenting: failure) {
            _ in Button("OK") { failure = nil }
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            "Remove \(live.name)?", isPresented: $isRemoveConfirmed, titleVisibility: .visible
        ) {
            Button("Remove Extension", role: .destructive) {
                store.remove(record.id)
                host.installedChanged()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its files and everything it stored in every space are deleted.")
        }
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                ExtensionIconView(
                    record: live,
                    actionIcon: host.actions.first { $0.id == live.id }?.iconPNG,
                    size: 44, directory: store.directory(for: live.id))
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.name).font(.headline)
                    Text("Version \(live.version) · manifest v\(live.manifestVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let description = live.descriptionText, !description.isEmpty {
                Text(description).font(.footnote).foregroundStyle(.secondary)
            }
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { live.isEnabled },
                    set: { on in
                        store.setEnabled(on, for: record.id)
                        host.installedChanged()
                    })
            )
            .accessibilityIdentifier("extensionEnabledToggle")
        }
    }

    private var statusSection: some View {
        Section {
            if let error = host.loadErrors[record.id] {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("WebKit refused to load this extension")
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            } else if !ExtensionHost.isSupported {
                Label(ExtensionHost.requirementNote, systemImage: "info.circle")
                    .font(.footnote)
            } else if live.isEnabled {
                Label(
                    host.isLoaded(record.id)
                        ? "Running in this space" : "Not loaded in this space yet",
                    systemImage: host.isLoaded(record.id) ? "checkmark.circle.fill" : "clock")
                .foregroundStyle(host.isLoaded(record.id) ? .green : .secondary)
            }
            ForEach(host.runtimeErrors(record.id), id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if live.hasOptionsPage {
                Button {
                    host.openOptionsPage(record.id)
                    state.isSettingsPresented = false
                } label: {
                    Label("Open its settings page", systemImage: "gearshape.2")
                }
                .disabled(!host.isLoaded(record.id))
                .accessibilityIdentifier("openOptionsPageButton")
            }
        }
    }

    private var permissions: [String] {
        (live.requestedPermissions + live.optionalPermissions).uniqued().sorted()
    }

    private var permissionsSection: some View {
        Section {
            ForEach(permissions, id: \.self) { permission in
                Toggle(
                    isOn: Binding(
                        get: { live.grantedPermissions.contains(permission) },
                        set: { on in
                            store.setPermission(permission, granted: on, for: record.id)
                            host.installedChanged()
                        })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ExtensionPermissionCopy.title(permission))
                        Text(ExtensionPermissionCopy.detail(permission))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("permissionToggle-\(permission)")
            }
        } header: {
            Text("Permissions")
        }
    }

    private var hostPatterns: [String] {
        (live.requestedHostPatterns + live.optionalHostPatterns).uniqued().sorted()
    }

    private var hostsSection: some View {
        Section {
            ForEach(hostPatterns, id: \.self) { pattern in
                Toggle(
                    isOn: Binding(
                        get: { live.grantedHostPatterns.contains(pattern) },
                        set: { on in
                            store.setHostPattern(pattern, granted: on, for: record.id)
                            host.installedChanged()
                        })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(InstalledExtension.hostLabel(pattern) ?? "Every site")
                        Text(pattern).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("hostToggle-\(pattern)")
            }
        } header: {
            Text("Site access")
        }
    }

    /// The per-site override, for whatever page is open behind Settings. This
    /// is the control people actually use — "not on my bank" — and it wins
    /// over the patterns above in both directions.
    @ViewBuilder
    private var thisSiteSection: some View {
        if let site = currentHost {
            Section {
                Picker(
                    "On \(site)",
                    selection: Binding(
                        get: { live.siteAccess[site].map(SiteChoice.init) ?? .default },
                        set: { choice in
                            store.setSiteAccess(choice.access, host: site, for: record.id)
                            host.installedChanged()
                        })
                ) {
                    ForEach(SiteChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("siteAccessPicker")
            } header: {
                Text("This site")
            } footer: {
                Text(
                    "Overrides the patterns above for this one host, in either direction — "
                        + "an extension granted every site can still be kept off one of them.")
            }
        }
    }

    private var currentHost: String? {
        guard let url = state.activeTab?.url, let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        return host
    }

    private var maintenanceSection: some View {
        Section {
            LabeledContent("Source", value: live.source.displayName)
            LabeledContent("Installed", value: live.installedAt.formatted(date: .abbreviated, time: .shortened))
            if live.source.isRefreshable {
                Button {
                    update()
                } label: {
                    HStack {
                        Label("Update from source", systemImage: "arrow.triangle.2.circlepath")
                        if isUpdating {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isUpdating)
                .accessibilityIdentifier("updateExtensionButton")
            }
            Button(role: .destructive) {
                isRemoveConfirmed = true
            } label: {
                Label("Remove Extension", systemImage: "trash")
            }
            .accessibilityIdentifier("removeExtensionButton")
        } footer: {
            Text(
                live.source.isRefreshable
                    ? "Updating re-reads the package from where it came from and keeps what "
                        + "you allowed."
                    : "This was installed from a file Zen no longer holds, so there is nothing "
                        + "to re-read — install the new version the same way to update it.")
        }
    }

    // MARK: Behaviour

    private func update() {
        guard !isUpdating else { return }
        isUpdating = true
        Task {
            defer { isUpdating = false }
            do {
                let prepared: PreparedExtension
                switch live.source {
                case .bundled(let name):
                    guard let url = ExtensionStore.bundledFixtureURL(name) else {
                        throw ExtensionArchive.ArchiveError.missingManifest
                    }
                    prepared = try store.prepare(directory: url, source: live.source)
                case .addons(let listing, _):
                    let resolution = try await AddonsSource.resolve(input: listing)
                    let data = try await AddonsSource.download(resolution.downloadURL)
                    prepared = try store.prepare(archive: data, source: resolution.source)
                case .file:
                    return
                }
                _ = try store.commit(
                    prepared,
                    grantedPermissions: Set(prepared.record.grantedPermissions),
                    grantedHostPatterns: Set(prepared.record.grantedHostPatterns))
                host.installedChanged()
            } catch {
                failure =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private enum SiteChoice: String, CaseIterable, Identifiable {
        case allow, `default`, deny

        init(_ access: InstalledExtension.SiteAccess) {
            self = access == .allow ? .allow : .deny
        }

        var id: String { rawValue }

        var access: InstalledExtension.SiteAccess? {
            switch self {
            case .allow: return .allow
            case .default: return nil
            case .deny: return .deny
            }
        }

        var title: String {
            switch self {
            case .allow: return "Allow"
            case .default: return "Default"
            case .deny: return "Never"
            }
        }
    }
}
