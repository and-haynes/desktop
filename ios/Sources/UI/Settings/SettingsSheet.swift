//  SettingsSheet.swift
//  Search engine, compact mode, spaces, and the keyboard-shortcut reference.

import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var state: BrowserState
    @ObservedObject var sync: SyncService
    /// Experimental (#008AD); inert until a vault is connected.
    @ObservedObject var vault: PasswordVaultService
    /// Experimental (#008B8); inert below iOS 18.4 and with nothing installed.
    @ObservedObject var extensions: ExtensionHost
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette
    @State private var editingSpace: Space?
    @State private var isCreatingSpace = false

    var body: some View {
        NavigationStack {
            Form {
                spaceOverrideNoticeSection
                appearanceSection
                textSizeSection
                navigationHelperSection

                Section {
                    Picker("Haptics", selection: $state.settings.hapticLevel) {
                        ForEach(HapticLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("hapticsPicker")
                    .onChange(of: state.settings.hapticLevel) { _, level in
                        // Answer the choice in its own language: the tap you
                        // just picked, played at once.
                        Haptics.shared.level = level
                        Haptics.shared.fire(.tabSelect)
                    }
                } header: {
                    Text("Haptics")
                } footer: {
                    Text(state.settings.hapticLevel.detail)
                }

                Section {
                    Picker("Sidebar position", selection: $state.settings.sidebarEdge) {
                        ForEach(SidebarEdge.allCases) { edge in
                            Text(edge.displayName).tag(edge)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("sidebarEdgePicker")
                    .onChange(of: state.settings.sidebarEdge) { _, _ in
                        Haptics.shared.fire(.layoutChange)
                    }
                } header: {
                    Text("Sidebar")
                } footer: {
                    Text(
                        "Zen desktop lets the vertical tab sidebar sit on either edge. This "
                            + "moves the drawer, its edge swipe, the URL bar's swipe-to-open "
                            + "gesture and the toolbar button to match.")
                }

                Section {
                    Picker("Bar fill", selection: $state.settings.barFill) {
                        ForEach(BarFill.allCases) { fill in
                            Text(fill.displayName).tag(fill)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("barFillPicker")

                    NavigationLink {
                        BarCustomizerView(state: state)
                            .environment(\.zenPalette, palette)
                    } label: {
                        HStack {
                            Label("Customize bar", systemImage: "slider.horizontal.3")
                            Spacer()
                            Text(
                                BarPreset.preset(id: state.settings.barLayout.presetID)?.name
                                    ?? "Custom"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("customizeBarRow")
                } header: {
                    Text("URL bar")
                } footer: {
                    Text(
                        state.settings.barFill.detail
                            + " Customize bar goes further: where the bar sits, how tall it "
                            + "is, what is inside the pill, which buttons it carries and what "
                            + "its gestures do.")
                }

                Section("Search") {
                    Picker("Search engine", selection: $state.settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Label(engine.displayName, systemImage: engine.symbol).tag(engine)
                        }
                    }
                    Toggle("Request desktop site", isOn: $state.settings.preferDesktopSite)
                }

                Section {
                    Toggle("Compact mode", isOn: $state.settings.compactModeEnabled)
                    Toggle("Hide sidebar", isOn: $state.settings.compactHidesSidebar)
                        .disabled(!state.settings.compactModeEnabled)
                    Toggle("Hide toolbar", isOn: $state.settings.compactHidesToolbar)
                        .disabled(!state.settings.compactModeEnabled)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Initial hide delay")
                            Spacer()
                            Text(String(format: "%.1fs", state.settings.compactHideDelay))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $state.settings.compactHideDelay, in: 0.5...5, step: 0.1)
                    }
                    .disabled(!state.settings.compactModeEnabled)
                } header: {
                    Text("Compact mode")
                } footer: {
                    Text(
                        "Zen keeps hiding the sidebar and hiding the toolbar as separate "
                            + "settings. The delay hides the chrome when compact mode starts. "
                            + "Tap or pull the grabber to reveal the toolbar; it stays until "
                            + "you tap or scroll the page. An opened sidebar stays until "
                            + "you dismiss it or choose a tab.")
                }

                if UIDevice.current.userInterfaceIdiom == .pad {
                    Section("iPad") {
                        Toggle("Keep sidebar open", isOn: $state.settings.sidebarPinnedOnPad)
                    }
                }

                ReaderSettingsSection(state: state)

                SyncSettingsSection(sync: sync)

                PasswordsSettingsSection(vault: vault)

                ExtensionsSettingsSection(host: extensions, state: state)

                Section("Spaces") {
                    ForEach(state.spaces) { space in
                        Button {
                            editingSpace = space
                        } label: {
                            HStack(spacing: 10) {
                                SpaceIconView(space: space, size: 15)
                                Text(space.name)
                                Spacer()
                                Circle()
                                    .fill(space.accent(isDark: palette.isDark).color)
                                    .frame(width: 16, height: 16)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .tint(.primary)
                    }
                    .onMove { state.moveSpace(from: $0, to: $1) }

                    Button {
                        isCreatingSpace = true
                    } label: {
                        Label("New Space", systemImage: "plus")
                    }
                }

                Section {
                    Toggle(
                        "Focus mode",
                        isOn: Binding(
                            get: { state.isFocusMode },
                            set: { _ in
                                NotificationCenter.default.post(
                                    name: .zenToggleFocusMode, object: nil)
                            }))
                    Toggle(
                        "Require Face ID to return",
                        isOn: $state.settings.focusRequiresBiometrics)
                } header: {
                    Text("Focus")
                } footer: {
                    Text(
                        "Focus opens a private, throwaway session with tracker and ad "
                            + "blocking and third-party cookies off. Nothing is written to "
                            + "history or session restore, and leaving Focus erases it.")
                }

                Section {
                    NavigationLink {
                        LocalNetworkView(state: state)
                            .environment(\.zenPalette, palette)
                    } label: {
                        HStack {
                            Label("Local network", systemImage: "network")
                            Spacer()
                            Text("\(state.localServices.services.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("localNetworkRow")

                    NavigationLink {
                        TrustedCertificatesView(store: state.trustedCertificates)
                    } label: {
                        HStack {
                            Label("LAN Certificates", systemImage: "checkmark.shield")
                            Spacer()
                            Text("\(state.trustedCertificates.certificates.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Home network")
                } footer: {
                    Text(
                        "Local network scans the subnet this device is on for services "
                            + "worth keeping, and the ones you import get aliases the "
                            + "address bar understands. Devices on a home network usually "
                            + "sign their own certificates; ones you have approved are "
                            + "listed here — swipe to forget.")
                }

                Section("Keyboard shortcuts") {
                    shortcut("New tab", "⌘T")
                    shortcut("Close tab", "⌘W")
                    shortcut("Focus address bar", "⌘L")
                    shortcut("Next / previous tab", "⌃Tab / ⌃⇧Tab")
                    shortcut("Toggle split view", "⇧⌘S")
                    shortcut("Toggle sidebar", "⇧⌘E")
                    shortcut("Text size", "⌘+ / ⌘− / ⌘0")
                    shortcut("Find in page", "⌘F")
                    shortcut("Cycle layout", "⇧⌘F")
                    shortcut("Focus mode", "⇧⌘P")
                    shortcut("Next / previous space", "⌃⇧→ / ⌃⇧←")
                }

                Section {
                    LabeledContent("Engine", value: "WKWebView (WebKit)")
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text(
                        "Zen for iOS reproduces Zen's interface on WebKit. Apple requires "
                            + "WebKit for browsers outside the EU, and Gecko — the engine "
                            + "desktop Zen is built on — has no iOS target.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // The sign-in sheet is presented here rather than inside
            // SyncSettingsSection: a `.sheet` attached to a Section inside a
            // Form never gets a presentation context, and silently does
            // nothing.
            .sheet(
                item: Binding(
                    get: { sync.pendingSignIn },
                    set: { if $0 == nil { sync.cancelSignIn() } })
            ) { request in
                FxASignInSheet(
                    request: request, diagnostics: sync.diagnostics,
                    onEvent: { event in handle(event) },
                    onCancel: { sync.cancelSignIn() })
            }
            .syncFailureAlert(sync.diagnostics)
            .sheet(item: $editingSpace) { SpaceEditorView(state: state, space: $0) }
            .sheet(isPresented: $isCreatingSpace) { SpaceEditorView(state: state, space: nil) }
        }
        .tint(palette.accent.color)
    }

    // MARK: Sections
    //
    // Split out of `body` deliberately: a `Form` with this many sections and
    // this many bindings in one expression pushes the type checker past its
    // budget, and the error it gives ("unable to type-check this expression in
    // reasonable time") names no cause. One property per section keeps each
    // one small enough to infer.

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $state.settings.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("appearancePicker")
            Toggle("Show status bar", isOn: $state.settings.showStatusBar)
                .accessibilityIdentifier("showStatusBarToggle")
            if state.settings.appearance == .sepia {
                Toggle("Tint pages", isOn: $state.settings.sepiaTintsPages)
                    .accessibilityIdentifier("sepiaTintPagesToggle")
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text(
                "Follow System uses the space's own colours to decide light or dark "
                    + "where the theme is strongly tinted, as Zen does. The status "
                    + "bar is hidden by default so the page gets the whole screen; "
                    + "the Dynamic Island is hardware and stays either way. Sepia "
                    + "warms the chrome; Tint pages extends that over the web itself, "
                    + "which is off by default because it is a filter over somebody "
                    + "else's design.")
        }
    }

    /// The global page-zoom default, and the way back from every site that
    /// has been told otherwise (#008B7). A segmented row rather than a slider:
    /// the ladder is discrete, and a slider would invite 103 %.
    @ViewBuilder
    private var textSizeSection: some View {
        Section {
            Picker("Default text size", selection: $state.settings.defaultPageZoom) {
                ForEach(PageZoom.steps, id: \.self) { step in
                    Text(PageZoom.percentLabel(step)).tag(step)
                }
            }
            .accessibilityIdentifier("defaultPageZoomPicker")

            Button(role: .destructive) {
                state.pageZoom.resetAll()
            } label: {
                HStack {
                    Text("Reset text size on all sites")
                    Spacer()
                    Text("\(state.pageZoom.zoomBySite.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .disabled(state.pageZoom.zoomBySite.isEmpty)
            .accessibilityIdentifier("resetAllPageZoom")
        } header: {
            Text("Text size")
        } footer: {
            Text(
                "The size a site is shown at is remembered per site, so a page "
                    + "you always find too small is too small once. Smaller and "
                    + "Larger are in the More menu on the bar, and on ⌘− / ⌘+ "
                    + "with a keyboard; ⌘0 puts a site back to this default.")
        }
    }

    /// What this screen is *not* deciding right now (#008BB).
    ///
    /// Without this the Settings screen is quietly wrong in any space that
    /// overrides something: the picker shows Card, the space is on Full
    /// Screen, and nothing on screen explains it. Named rather than counted,
    /// because "3 values overridden" sends you hunting.
    @ViewBuilder
    private var spaceOverrideNoticeSection: some View {
        if let space = state.activeSpace, let overrides = space.display, !overrides.isEmpty {
            Section {
                Button {
                    editingSpace = space
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(palette.accent.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(space.name) overrides these here")
                                .font(.callout)
                            Text(overrides.overriddenNames.joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.primary)
                .accessibilityIdentifier("spaceOverrideNotice")
            } footer: {
                Text(
                    "The settings below are the defaults every space inherits. "
                        + "This space has been told otherwise about the values "
                        + "listed; its own Display section is where to change them.")
            }
        }
    }

    /// The four page-stepping buttons (#008B9). The side offers Automatic
    /// first because that is the answer most people want and none of them
    /// would think to ask for: the edge *opposite* the sidebar, where the
    /// thumb is not already busy.
    @ViewBuilder
    private var navigationHelperSection: some View {
        Section {
            Toggle("Navigation helper", isOn: $state.settings.navigationHelperEnabled)
                .accessibilityIdentifier("navigationHelperToggle")
            Picker("Position", selection: $state.settings.navigationHelperPlacement) {
                ForEach(NavigationHelperPlacement.allCases) { placement in
                    Text(placement.displayName).tag(placement)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!state.settings.navigationHelperEnabled)
            .accessibilityIdentifier("navigationHelperPlacementPicker")
            .onChange(of: state.settings.navigationHelperPlacement) { _, _ in
                Haptics.shared.fire(.layoutChange)
            }
            if state.settings.navigationHelperPlacement == .side {
                Picker("Side", selection: $state.settings.navigationHelperSide) {
                    Text("Automatic").tag(SidebarEdge?.none)
                    ForEach(SidebarEdge.allCases) { edge in
                        Text(edge.displayName).tag(SidebarEdge?.some(edge))
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!state.settings.navigationHelperEnabled)
                .accessibilityIdentifier("navigationHelperSidePicker")
            }
        } header: {
            Text("Navigation helper")
        } footer: {
            Text(navigationHelperFooter)
        }
    }

    /// Built as a `String` rather than inline in the `Text`: string
    /// interpolation inside a `Form` this large is what tips the type checker
    /// over, and the error it gives names no cause.
    private var navigationHelperFooter: String {
        let position = state.settings.navigationHelperPlacement == .bottom
            ? "Bottom puts all four controls in a row near the bottom of the page."
            : "Automatic places them opposite the sidebar."
        return "Jump to the top or bottom, or move one screenful at a time. "
            + "Controls appear as you scroll and fade after the compact-mode delay. " + position
    }

    /// The sign-in sheet's three outcomes. Kept out of the body so the Form's
    /// modifier chain stays something the type checker can finish.
    private func handle(_ event: FxASignInEvent) {
        switch event {
        case .login(let login):
            Task { await sync.completeSignIn(login: login) }
        case .redirect(let url):
            Task { await sync.completeSignIn(callback: url) }
        case .signOutRequested:
            Task { await sync.signOut() }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        let commit = info?["ZenGitCommit"] as? String ?? "dev"
        return "\(short) (\(build)) · \(commit)"
    }

    private func shortcut(_ label: String, _ keys: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(keys)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
