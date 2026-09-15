//  SettingsSheet.swift
//  Search engine, compact mode, spaces, and the keyboard-shortcut reference.

import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var state: BrowserState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette
    @State private var editingSpace: Space?
    @State private var isCreatingSpace = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $state.settings.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("appearancePicker")
                } header: {
                    Text("Appearance")
                } footer: {
                    Text(
                        "Follow System uses the space's own colours to decide light or dark "
                            + "where the theme is strongly tinted, as Zen does.")
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
                            Text("Hide after scrolling")
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
                            + "settings. The bar returns while you scroll and fades again "
                            + "shortly after; the grabber above the home indicator brings it "
                            + "back deliberately.")
                }

                if UIDevice.current.userInterfaceIdiom == .pad {
                    Section("iPad") {
                        Toggle("Keep sidebar open", isOn: $state.settings.sidebarPinnedOnPad)
                    }
                }

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

                Section("Keyboard shortcuts") {
                    shortcut("New tab", "⌘T")
                    shortcut("Close tab", "⌘W")
                    shortcut("Focus address bar", "⌘L")
                    shortcut("Next / previous tab", "⌃Tab / ⌃⇧Tab")
                    shortcut("Toggle split view", "⇧⌘S")
                    shortcut("Toggle sidebar", "⇧⌘E")
                    shortcut("Find in page", "⌘F")
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
            .sheet(item: $editingSpace) { SpaceEditorView(state: state, space: $0) }
            .sheet(isPresented: $isCreatingSpace) { SpaceEditorView(state: state, space: nil) }
        }
        .tint(palette.accent.color)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
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
