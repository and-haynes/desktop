//  BarCustomizerView.swift
//  "Customize bar" — the editor for `BarLayout` (#00896).
//
//  Quiche Browser's customiser is worth copying because of one decision: the
//  preview is the *real control*, live, at the top, and every section below it
//  changes what you are already looking at. So this writes through to
//  `state.settings.barLayout` on every edit — the bar behind the sheet moves
//  too — and keeps an undo stack rather than a Cancel button, because a sheet
//  you have to commit or discard makes experimenting expensive.

import SwiftUI
import UniformTypeIdentifiers

struct BarCustomizerView: View {
    @ObservedObject var state: BrowserState
    @StateObject private var presets = BarPresetStore()
    @Environment(\.zenPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// Snapshots, newest last. Sliders coalesce into one entry per gesture —
    /// see `record()`.
    @State private var undoStack: [BarLayout] = []
    @State private var lastRecorded = Date.distantPast
    @State private var isNamingPreset = false
    @State private var presetName = ""
    @State private var exportDocument: BarLayoutDocument?
    @State private var isImporting = false
    @State private var importError: String?

    private var layout: Binding<BarLayout> {
        Binding(get: { state.settings.barLayout }, set: { state.settings.barLayout = $0 })
    }

    private var current: BarLayout { state.settings.barLayout }

    var body: some View {
        Form {
            previewSection
            presetSection
            positionSection
            lookSection
            contentsSection
            buttonsSection
            gestureSection
            autoHideSection
            transferSection
        }
        .navigationTitle("Customize bar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(undoStack.isEmpty)
                .accessibilityLabel("Undo last change")
                .accessibilityIdentifier("barUndo")
            }
        }
        .alert("Save preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                presets.save(current, as: presetName)
                presetName = ""
            }
        } message: {
            Text("Keeps the bar exactly as it is now under a name you can come back to.")
        }
        .alert(
            "Could not import that file", isPresented: .constant(importError != nil),
            presenting: importError
        ) { _ in
            Button("OK") { importError = nil }
        } message: { reason in
            Text(reason)
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument, contentType: .json,
            defaultFilename: "zen-bar-layout"
        ) { _ in
            exportDocument = nil
        }
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: [.json, .item]
        ) { result in
            importLayout(result)
        }
    }

    // MARK: Preview

    /// The real `OmniboxPill`, drawn but not wired up, over a stand-in for the
    /// page. Using the actual bar is the point — a hand-drawn mock would agree
    /// with the bar right up until it stopped.
    private var previewSection: some View {
        Section {
            ZStack(alignment: current.position.isTop ? .top : .bottom) {
                ZenGradientView(
                    theme: state.activeSpace?.theme ?? ZenTheme.default,
                    isDark: palette.isDark
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    // Something with contrast behind the bar, so Transparent
                    // and low blur strengths read honestly.
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<4, id: \.self) { row in
                            Capsule()
                                .fill(palette.text.withAlpha(0.18).color)
                                .frame(height: 8)
                                .padding(.trailing, CGFloat(row % 3) * 40)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                OmniboxPill(state: state, isFloating: true, isPreview: true)
                    .padding(.horizontal, max(CGFloat(current.horizontalMargin), 4))
                    .padding(
                        current.position.isTop ? .top : .bottom,
                        CGFloat(current.verticalOffset) + 10)
            }
            .frame(height: 148)
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: current)
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .accessibilityIdentifier("barPreview")
        } header: {
            Text("Preview")
        } footer: {
            Text(
                "Every change below shows here — and on the real bar behind this "
                    + "sheet — straight away. Undo, top right, steps back one change.")
        }
    }

    // MARK: Presets

    private var presetSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(BarPreset.all) { preset in
                        presetChip(
                            name: preset.name, isCurrent: current.presetID == preset.id,
                            detail: preset.detail
                        ) {
                            apply(preset.layout)
                        }
                    }
                    ForEach(presets.presets) { saved in
                        presetChip(name: saved.name, isCurrent: false, detail: "Saved") {
                            apply(saved.layout)
                        } onDelete: {
                            presets.remove(saved)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            Button {
                presetName = ""
                isNamingPreset = true
            } label: {
                Label("Save current as preset", systemImage: "square.and.arrow.down")
            }

            if let preset = BarPreset.preset(id: current.presetID) {
                Button {
                    apply(preset.layout)
                } label: {
                    Label("Reset to \(preset.name)", systemImage: "arrow.counterclockwise")
                }
                .disabled(current == preset.layout)
            } else {
                Button {
                    apply(BarPreset.zen.layout)
                } label: {
                    Label("Reset to Zen", systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text("Presets")
        } footer: {
            Text(
                current.presetID.flatMap { BarPreset.preset(id: $0)?.detail }
                    ?? "Edited. Reset goes back to the preset this started from.")
        }
    }

    private func presetChip(
        name: String, isCurrent: Bool, detail: String, apply: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        Button(action: apply) {
            VStack(spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 96)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isCurrent
                            ? palette.accent.withAlpha(0.2).color
                            : palette.toolbarElementHoverBG.color)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isCurrent ? palette.accent.color : palette.border.color,
                        lineWidth: isCurrent ? 1.5 : 0.5)
            }
        }
        .tint(.primary)
        .accessibilityIdentifier("barPreset-\(name)")
        .contextMenu {
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete preset", systemImage: "trash")
                }
            }
        }
    }

    // MARK: Position & shape

    private var positionSection: some View {
        Section {
            Picker("Position", selection: bind(\.position)) {
                ForEach(BarPosition.allCases) { position in
                    Label(position.displayName, systemImage: position.symbol).tag(position)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("barPositionPicker")

            HStack {
                Text("Height")
                Spacer()
                ForEach(BarHeightStep.allCases) { step in
                    Button(step.displayName) {
                        record()
                        layout.wrappedValue.height = step.points
                        layout.wrappedValue.presetID = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(current.heightStep == step ? palette.accent.color : .secondary)
                }
            }
            slider("Height", value: bind(\.height), range: BarLayout.minHeight...BarLayout.maxHeight, unit: "pt")
            slider(
                "Corner radius", value: bind(\.cornerRadius),
                range: 0...BarLayout.maxCornerRadius, unit: "pt")
            slider(
                "Side margin", value: bind(\.horizontalMargin),
                range: 0...BarLayout.maxHorizontalMargin, unit: "pt")
            slider(
                "Offset from the edge", value: bind(\.verticalOffset),
                range: 0...BarLayout.maxVerticalOffset, unit: "pt")
            Toggle("Pill", isOn: bind(\.isPill))
        } header: {
            Text("Position & shape")
        } footer: {
            Text(
                "Floating puts the bar over the page; Bottom and Top give it a "
                    + "row of its own. A pill is inset from the screen edges — turn "
                    + "it off for a bar that runs the full width.")
        }
    }

    // MARK: Fill & look

    private var lookSection: some View {
        Section {
            Picker("Fill", selection: fillBinding) {
                Text("Follow Settings").tag(BarFill?.none)
                ForEach(BarFill.allCases) { fill in
                    Text(fill.displayName).tag(BarFill?.some(fill))
                }
            }
            .accessibilityIdentifier("barFillOverride")

            Toggle(
                "Custom colour",
                isOn: Binding(
                    get: { current.customColor != nil },
                    set: { on in
                        record()
                        layout.wrappedValue.customColor = on ? palette.urlbarBackground : nil
                        layout.wrappedValue.presetID = nil
                    }))

            if current.customColor != nil {
                ColorPicker(
                    "Colour",
                    selection: Binding(
                        get: { (current.customColor ?? palette.urlbarBackground).color },
                        set: { colour in
                            record()
                            layout.wrappedValue.customColor =
                                ZenColor(colour) ?? palette.urlbarBackground
                            layout.wrappedValue.presetID = nil
                        }), supportsOpacity: false)
                slider("Opacity", value: bind(\.customColorOpacity), range: 0...1, unit: "%")
            }

            slider("Blur", value: bind(\.blurStrength), range: 0...1, unit: "%")
            Toggle("Border", isOn: bind(\.showsBorder))
            Toggle("Shadow", isOn: bind(\.showsShadow))
            slider(
                "URL text size", value: bind(\.urlFontSize),
                range: BarLayout.minURLFontSize...BarLayout.maxURLFontSize, unit: "pt")

            Picker("Accent", selection: bind(\.accentSource)) {
                ForEach(BarAccentSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            if current.accentSource == .fixed {
                ColorPicker(
                    "Bar accent",
                    selection: Binding(
                        get: { (current.fixedAccent ?? palette.accent).color },
                        set: { colour in
                            record()
                            layout.wrappedValue.fixedAccent = ZenColor(colour) ?? palette.accent
                            layout.wrappedValue.presetID = nil
                        }), supportsOpacity: false)
            }

            Toggle("Haptics from the bar", isOn: bind(\.haptics))
        } header: {
            Text("Fill & look")
        } footer: {
            Text(
                "Follow Settings uses the Bar fill choice above — Liquid Glass, "
                    + "Matte or Transparent. A custom colour replaces it entirely; "
                    + "Blur is how much of the frosted material shows through "
                    + "underneath. Haptics here only silences the bar; the global "
                    + "level still applies on top.")
        }
    }

    // MARK: Contents

    private var contentsSection: some View {
        Section {
            Toggle("Favicon", isOn: bind(\.contents.showsFavicon))
            Toggle("Security badge", isOn: bind(\.contents.showsSecurityBadge))
            Picker("Label", selection: bind(\.contents.label)) {
                ForEach(BarLabelStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            Picker("Progress", selection: bind(\.contents.progress)) {
                ForEach(BarProgressStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Find button", isOn: bind(\.contents.showsFindButton))
        } header: {
            Text("Pill contents")
        } footer: {
            Text(
                "Line draws the progress under the bar; Fill runs it across the "
                    + "bar's own surface, which costs no height. There is no reader "
                    + "affordance because WebKit exposes no reader API to third-party "
                    + "apps — see the README.")
        }
    }

    // MARK: Buttons

    private var buttonsSection: some View {
        Section {
            BarSlotEditor(layout: layout, willChange: { record() })
                .environment(\.zenPalette, palette)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        } header: {
            Text("Buttons")
        } footer: {
            Text(
                "Left and right hold \(BarLayout.maxSlotItems) each; the overflow "
                    + "menu holds \(BarLayout.maxOverflowItems). Hold a button to give "
                    + "it a second action on a long press. Erase is not in the list: "
                    + "in Focus mode it is always on the bar, which is the whole "
                    + "promise of the mode.")
        }
    }

    // MARK: Gestures

    private var gestureSection: some View {
        Section {
            ForEach(BarGesture.allCases) { gesture in
                Picker(selection: gestureBinding(gesture)) {
                    ForEach(BarAction.gestureLibrary) { action in
                        Text(action.title).tag(action)
                    }
                } label: {
                    Label(gesture.title, systemImage: gesture.symbol)
                }
                .accessibilityIdentifier("barGesture-\(gesture.rawValue)")
            }
        } header: {
            Text("Bar gestures")
        } footer: {
            Text(
                "A swipe has to travel \(Int(BarSwipeGesture.distanceThreshold))pt, or "
                    + "\(Int(BarSwipeGesture.flickDistance))pt quickly — so the taps and "
                    + "the buttons all still work. Action Menu is the system's own "
                    + "press-and-hold menu, showing whatever is in the overflow slot.")
        }
    }

    // MARK: Auto-hide

    private var autoHideSection: some View {
        Section {
            Picker("Auto-hide", selection: bind(\.autoHide)) {
                ForEach(BarAutoHide.allCases) { rule in
                    Text(rule.displayName).tag(rule)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("barAutoHidePicker")

            Picker("Landscape position", selection: landscapePositionBinding) {
                Text("Same").tag(BarPosition?.none)
                ForEach(BarPosition.allCases) { position in
                    Text(position.displayName).tag(BarPosition?.some(position))
                }
            }
            Picker("Landscape auto-hide", selection: landscapeAutoHideBinding) {
                Text("Same").tag(BarAutoHide?.none)
                ForEach(BarAutoHide.allCases) { rule in
                    Text(rule.displayName).tag(BarAutoHide?.some(rule))
                }
            }
        } header: {
            Text("Auto-hide")
        } footer: {
            Text(
                current.autoHide.detail
                    + " The grabber above the home indicator brings the bar back from "
                    + "any of these.")
        }
    }

    // MARK: Import / export

    private var transferSection: some View {
        Section {
            Button {
                exportDocument = BarLayoutDocument(layout: current)
            } label: {
                Label("Export layout…", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("barExport")
            Button {
                isImporting = true
            } label: {
                Label("Import layout…", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("barImport")
        } header: {
            Text("Layout file")
        } footer: {
            Text(
                "Plain JSON, so it can be edited by hand or kept in a dotfiles repo. "
                    + "An import that is partly unreadable keeps whatever it can "
                    + "understand rather than failing outright.")
        }
    }

    private func importLayout(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            // A file from the document picker lives outside our sandbox until
            // the scoped resource is opened.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                importError = "That file could not be read."
                return
            }
            guard let imported = try? JSONDecoder().decode(BarLayout.self, from: data) else {
                importError = "That does not look like a Zen bar layout."
                return
            }
            apply(imported.normalised())
        }
    }

    // MARK: Bindings and undo

    /// A binding that snapshots for undo before it writes, and clears the
    /// preset marker — an edited preset is no longer that preset.
    private func bind<Value: Equatable>(
        _ keyPath: WritableKeyPath<BarLayout, Value>
    ) -> Binding<Value> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { newValue in
                guard current[keyPath: keyPath] != newValue else { return }
                record()
                var next = current
                next[keyPath: keyPath] = newValue
                next.presetID = nil
                state.settings.barLayout = next
            })
    }

    private var fillBinding: Binding<BarFill?> {
        Binding(
            get: { current.fill },
            set: { newValue in
                record()
                var next = current
                next.fill = newValue
                next.presetID = nil
                state.settings.barLayout = next
            })
    }

    private var landscapePositionBinding: Binding<BarPosition?> {
        Binding(
            get: { current.landscape.position },
            set: { newValue in
                record()
                var next = current
                next.landscape.position = newValue
                next.presetID = nil
                state.settings.barLayout = next
            })
    }

    private var landscapeAutoHideBinding: Binding<BarAutoHide?> {
        Binding(
            get: { current.landscape.autoHide },
            set: { newValue in
                record()
                var next = current
                next.landscape.autoHide = newValue
                next.presetID = nil
                state.settings.barLayout = next
            })
    }

    private func gestureBinding(_ gesture: BarGesture) -> Binding<BarAction> {
        Binding(
            get: { current.gestures[gesture] ?? .none },
            set: { action in
                guard current.gestures[gesture] != action else { return }
                record()
                var next = current
                next.setGesture(action, for: gesture)
                state.settings.barLayout = next
            })
    }

    private func slider(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(
                    unit == "%"
                        ? "\(Int((value.wrappedValue * 100).rounded()))%"
                        : "\(Int(value.wrappedValue.rounded()))\(unit)"
                )
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    private func apply(_ next: BarLayout) {
        record(force: true)
        state.settings.barLayout = next.normalised()
        Haptics.shared.fire(.layoutChange)
    }

    /// Push a snapshot, coalescing a burst into one entry.
    ///
    /// A `Slider` writes on every frame of a drag, so recording each write
    /// would fill the stack with sixty near-identical layouts and make Undo
    /// useless. Anything inside the window joins the entry already on top.
    private func record(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastRecorded) < 0.8, !undoStack.isEmpty {
            lastRecorded = now
            return
        }
        lastRecorded = now
        undoStack.append(current)
        // Deep enough to get out of trouble, shallow enough not to be a memory
        // leak someone finds in six months.
        if undoStack.count > 40 { undoStack.removeFirst() }
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        lastRecorded = .distantPast
        Haptics.shared.fire(.tabRestore)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            state.settings.barLayout = previous
        }
    }
}

// MARK: - The layout file

/// `BarLayout` as a document, for the share sheet and Files.
struct BarLayoutDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var layout: BarLayout

    init(layout: BarLayout) { self.layout = layout }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        layout = try JSONDecoder().decode(BarLayout.self, from: data).normalised()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(layout))
    }
}
