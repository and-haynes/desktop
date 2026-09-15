//  ExtensionsPanel.swift
//  The extension buttons, as a menu on the bar and as a sheet from a gesture.
//
//  A toolbar full of extension icons is a desktop idea; a phone bar has room
//  for about five glyphs in total. So every installed extension's action lives
//  behind one puzzle-piece button — a `Menu` when it is a slot on the bar,
//  which is where the badge text can be read at a glance, and a sheet when it
//  is reached from a gesture or from the More menu, because a gesture has
//  nowhere to anchor a popover.

import SwiftUI

/// The rows: one per loaded extension, plus the way to Settings.
struct ExtensionMenuItems: View {
    @ObservedObject var host: ExtensionHost
    @ObservedObject var state: BrowserState

    var body: some View {
        if !ExtensionHost.isSupported {
            Button {
                state.isSettingsPresented = true
            } label: {
                Label("Extensions need iOS 18.4", systemImage: "puzzlepiece.extension")
            }
        } else if host.menuActions.isEmpty {
            Button {
                state.isSettingsPresented = true
            } label: {
                Label(
                    host.hasAnythingInstalled ? "No extensions on this page" : "Add an Extension…",
                    systemImage: "puzzlepiece.extension")
            }
        } else {
            ForEach(host.menuActions) { action in
                Button {
                    Haptics.shared.fire(.tabSelect)
                    host.performAction(action.id)
                } label: {
                    Label {
                        Text(action.badgeText.isEmpty ? action.label : "\(action.label)  ·  \(action.badgeText)")
                    } icon: {
                        if let data = action.iconPNG, let image = UIImage(data: data) {
                            Image(uiImage: image).renderingMode(.original)
                        } else {
                            Image(systemName: "puzzlepiece.extension")
                        }
                    }
                }
                .accessibilityIdentifier("extensionAction-\(action.id)")
            }
            Divider()
            Button {
                state.isSettingsPresented = true
            } label: {
                Label("Manage Extensions…", systemImage: "gearshape")
            }
        }
    }
}

/// The same list as a sheet, for the paths that cannot show a menu.
struct ExtensionsPanel: View {
    @ObservedObject var host: ExtensionHost
    @ObservedObject var state: BrowserState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette

    var body: some View {
        NavigationStack {
            List {
                if !ExtensionHost.isSupported {
                    Section {
                        Label(ExtensionHost.requirementNote, systemImage: "info.circle")
                            .font(.footnote)
                    }
                } else if host.menuActions.isEmpty {
                    Section {
                        Text(
                            host.hasAnythingInstalled
                                ? "None of your extensions has anything to offer on this page."
                                : "No extensions are installed yet.")
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(host.menuActions) { action in
                            Button {
                                host.performAction(action.id)
                                dismiss()
                            } label: {
                                actionRow(action)
                            }
                            .tint(.primary)
                            .accessibilityIdentifier("extensionPanelAction-\(action.id)")
                        }
                    } header: {
                        Text("On this page")
                    }
                }

                Section {
                    Button {
                        dismiss()
                        state.isSettingsPresented = true
                    } label: {
                        Label("Manage Extensions", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Extensions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .tint(palette.accent.color)
        .accessibilityIdentifier("extensionsPanel")
    }

    private func actionRow(_ action: ExtensionActionState) -> some View {
        HStack(spacing: 12) {
            if let data = action.iconPNG, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(action.name)
                Text(action.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !action.badgeText.isEmpty {
                Text(action.badgeText)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.accent.withAlpha(0.25).color))
            }
        }
    }
}
