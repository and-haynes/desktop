//  ReaderSettingsSection.swift
//  Reader mode in Settings: the defaults every site starts from, and the way to
//  forget the sites that have since disagreed (#008BC).
//
//  One row into a pushed screen rather than a dozen rows in the Form. Two
//  reasons, in order: the controls belong *next to an article*, where you can
//  see what they do, so this screen is for the one thing the panel cannot do —
//  set the starting point for sites you have not opened yet; and `SettingsSheet`'s
//  Form is already at the type checker's budget (see its own note), so a
//  section that added a dozen bindings to it would not compile.

import SwiftUI

struct ReaderSettingsSection: View {
    @ObservedObject var state: BrowserState
    @StateObject private var sites = ReaderSiteStore()

    var body: some View {
        Section {
            NavigationLink {
                ReaderDefaultsScreen(state: state, sites: sites)
            } label: {
                Label("Reader", systemImage: "doc.plaintext")
            }
            .accessibilityIdentifier("readerSettingsRow")
        } footer: {
            Text(
                "Articles open with these. Change anything while reading and that site "
                    + "keeps its own version from then on.")
        }
    }
}

/// The global defaults, plus what the per-site memory currently holds.
private struct ReaderDefaultsScreen: View {
    @ObservedObject var state: BrowserState
    @ObservedObject var sites: ReaderSiteStore
    @Environment(\.zenPalette) private var palette

    private var settings: ReaderSettings { state.settings.readerDefaults }

    var body: some View {
        Form {
            specimenSection
            typeSection
            layoutSection
            pageSection
            sitesSection
        }
        .navigationTitle("Reader")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The controls are numbers until you see them on type. A live specimen in
    /// the theme and face being chosen is the cheapest honest preview there is.
    private var specimenSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("The Bee Orchid")
                    .font(.system(size: settings.fontSize + 6, weight: .bold))
                Text(
                    "Its flowers resemble bees, and it is this mimicry that attracts "
                        + "the insect on which the plant depends."
                )
                .font(.system(size: settings.fontSize))
                .lineSpacing(settings.fontSize * (settings.lineHeight - 1))
                .multilineTextAlignment(
                    settings.alignment == .justified ? .leading : .leading)
            }
            .foregroundStyle(settings.palette.text.color)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(settings.palette.background.color)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .accessibilityIdentifier("readerSpecimen")
        }
    }

    private var typeSection: some View {
        Section("Type") {
            Picker("Typeface", selection: $state.settings.readerDefaults.font) {
                ForEach(ReaderFont.allCases) { font in
                    Text(font.displayName).tag(font)
                }
            }
            Picker("Theme", selection: $state.settings.readerDefaults.theme) {
                ForEach(ReaderTheme.allCases) { theme in
                    Label(theme.displayName, systemImage: theme.symbol).tag(theme)
                }
            }
            row("Size", "\(Int(settings.fontSize))") {
                Slider(
                    value: $state.settings.readerDefaults.fontSize,
                    in: ReaderSettings.fontSizeRange, step: 1)
            }
            row("Line height", String(format: "%.2f", settings.lineHeight)) {
                Slider(
                    value: $state.settings.readerDefaults.lineHeight,
                    in: ReaderSettings.lineHeightRange, step: 0.05)
            }
        }
    }

    private var layoutSection: some View {
        Section("Layout") {
            row("Column width", "\(Int(settings.contentWidth))pt") {
                Slider(
                    value: $state.settings.readerDefaults.contentWidth,
                    in: ReaderSettings.contentWidthRange, step: 10)
            }
            Picker("Alignment", selection: $state.settings.readerDefaults.alignment) {
                ForEach(ReaderAlignment.allCases) { alignment in
                    Text(alignment.displayName).tag(alignment)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Hyphenate justified text", isOn: $state.settings.readerDefaults.hyphenation)
                .disabled(settings.alignment != .justified)
        }
    }

    private var pageSection: some View {
        Section("Page") {
            Toggle("Images", isOn: $state.settings.readerDefaults.showImages)
            Toggle("Drop cap", isOn: $state.settings.readerDefaults.dropCaps)
            row("Read aloud speed", String(format: "%.2f×", settings.speechRate / 0.5)) {
                Slider(
                    value: $state.settings.readerDefaults.speechRate,
                    in: ReaderSettings.speechRateRange, step: 0.01)
            }
        }
    }

    private var sitesSection: some View {
        Section {
            if sites.settingsBySite.isEmpty {
                Text("No site has its own settings yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sites.settingsBySite.keys.sorted(), id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Text(sites.settingsBySite[site]?.theme.displayName ?? "")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Forget every site", role: .destructive) {
                    Haptics.shared.fire(.tabClose)
                    sites.resetAll()
                }
                .accessibilityIdentifier("readerForgetSites")
            }
        } header: {
            Text("Sites with their own settings")
        } footer: {
            Text(
                "A site is remembered by its domain, so every page on it opens the "
                    + "way you last left one.")
        }
    }

    private func row<Control: View>(
        _ title: String, _ readout: String, @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(readout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            control()
        }
    }
}
