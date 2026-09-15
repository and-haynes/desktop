//  SpaceEditorView.swift
//  Create or edit a space: name, icon, and the gradient theme.
//
//  The theme picker is the touch equivalent of Zen's colour wheel: you place a
//  primary dot and pick a harmony, and the other dots are derived with the same
//  hue offsets the desktop picker snaps to.

import SwiftUI

struct SpaceEditorView: View {
    @ObservedObject var state: BrowserState
    /// nil means "create a new space".
    let space: Space?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var name: String
    @State private var icon: String
    @State private var isSymbol: Bool
    @State private var theme: ZenTheme
    @State private var emojiDraft: String

    init(state: BrowserState, space: Space?) {
        self.state = state
        self.space = space
        _name = State(initialValue: space?.name ?? "")
        _icon = State(initialValue: space?.icon ?? "sparkles")
        _isSymbol = State(initialValue: space?.isSymbol ?? true)
        _emojiDraft = State(initialValue: space.map { $0.isSymbol ? "" : $0.icon } ?? "")
        _theme = State(
            initialValue: space?.theme
                ?? ZenGradientGenerator.theme(
                    seed: ZenColor(hueDegrees: .random(in: 0..<360), saturation: 95, lightness: 60),
                    harmony: .analogous))
    }

    private var palette: ZenPalette {
        let dark = theme.forcedDarkMode ?? (colorScheme == .dark)
        return ZenPalette(accent: theme.accentColor(isDark: dark), isDark: dark)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Space name", text: $name)
                }

                Section("Icon") {
                    iconPicker
                }

                Section {
                    ZenGradientView(theme: theme, isDark: palette.isDark)
                        .frame(height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .listRowInsets(EdgeInsets())
                    wheel
                    harmonyPicker
                    textureSlider
                } header: {
                    Text("Theme")
                } footer: {
                    Text(
                        "Zen derives the whole interface palette from one accent. "
                            + "The dot you place is the accent; the others follow the harmony.")
                }

                if let space, state.spaces.count > 1 {
                    Section {
                        Button(role: .destructive) {
                            state.removeSpace(space.id)
                            dismiss()
                        } label: {
                            Label("Delete Space", systemImage: "trash")
                        }
                    } footer: {
                        Text("Deleting a space closes its tabs. Essentials are kept.")
                    }
                }
            }
            .navigationTitle(space == nil ? "New Space" : "Edit Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(resolvedName.isEmpty)
                }
            }
        }
        .tint(palette.accent.color)
    }

    private var resolvedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Icon

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Emoji", text: $emojiDraft)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 22))
                    .onChange(of: emojiDraft) { _, new in
                        // Keep one character; an emoji picker is the keyboard's job.
                        if let first = new.first {
                            emojiDraft = String(first)
                            icon = String(first)
                            isSymbol = false
                        } else if new.isEmpty, !isSymbol {
                            isSymbol = true
                            icon = "sparkles"
                        }
                    }
                Text("or pick a symbol")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Space.symbolChoices, id: \.self) { symbol in
                        Button {
                            icon = symbol
                            isSymbol = true
                            emojiDraft = ""
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 16))
                                .frame(width: 38, height: 38)
                                .background {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(
                                            isSymbol && icon == symbol
                                                ? palette.accent.withAlpha(0.3).color
                                                : Color.secondary.opacity(0.12))
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Theme

    /// A simplified stand-in for the 380×380 wheel: hue across, lightness down,
    /// saturation pinned to the 90–100% band the desktop picker uses.
    private var wheel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accent")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(stride(from: 0.0, to: 360.0, by: 15.0)), id: \.self) { hue in
                        ForEach([48.0, 62.0], id: \.self) { lightness in
                            swatch(
                                ZenColor(hueDegrees: hue, saturation: 95, lightness: lightness))
                        }
                    }
                    swatch(ZenColor(hueDegrees: 0, saturation: 0, lightness: 30))
                    swatch(ZenColor(hueDegrees: 0, saturation: 0, lightness: 75))
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func swatch(_ color: ZenColor) -> some View {
        let selected = theme.primaryDotColor == color
        return Button {
            theme = ZenGradientGenerator.theme(seed: color, harmony: theme.harmony)
        } label: {
            Circle()
                .fill(color.color)
                .frame(width: 26, height: 26)
                .overlay {
                    Circle().strokeBorder(
                        selected ? Color.primary : .clear, lineWidth: 2)
                }
        }
        .buttonStyle(.plain)
    }

    private var harmonyPicker: some View {
        Picker("Harmony", selection: $theme.harmony) {
            ForEach(ZenColorHarmony.allCases) { Text($0.displayName).tag($0) }
        }
        .onChange(of: theme.harmony) { _, harmony in
            guard let seed = theme.primaryDotColor else { return }
            theme = ZenGradientGenerator.theme(seed: seed, harmony: harmony)
        }
    }

    /// `--zen-grainy-background-opacity`.
    private var textureSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Grain")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Slider(value: $theme.texture, in: 0...1)
        }
    }

    private func save() {
        let finalName = resolvedName
        if let space {
            state.updateSpace(space.id) {
                $0.name = finalName
                $0.icon = icon
                $0.isSymbol = isSymbol
                $0.theme = theme
            }
        } else {
            state.addSpace(name: finalName, icon: icon, isSymbol: isSymbol, theme: theme)
        }
        dismiss()
    }
}
