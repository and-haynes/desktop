//  ReaderControlsPanel.swift
//  Every appearance control, in a sheet you can see the article through
//  (#008BC).
//
//  The detents matter more than they look. At `.medium` the sheet covers the
//  bottom half and `presentationBackgroundInteraction` leaves the article live
//  above it, so dragging the size slider is a thing you *watch happen* rather
//  than a thing you set, dismiss, judge, and come back to. That single property
//  is most of the difference between a control panel and a preferences screen.
//
//  The panel writes straight into `ReaderController.settings`. Everything
//  downstream — restyling the page, remembering the choice for this site — is
//  that value's `didSet`, so no control here has to know it exists.

import SwiftUI

struct ReaderControlsPanel: View {
    @ObservedObject var reader: ReaderController
    @ObservedObject var state: BrowserState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette
    @StateObject private var recents = RecentColorsStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    themeSection
                    if reader.settings.theme == .custom { customColourSection }
                    faceSection
                    sizeSection
                    rhythmSection
                    measureSection
                    alignmentSection
                    dimSection
                    pageSection
                    voiceSection
                    siteSection
                }
                .padding(16)
            }
            .navigationTitle("Reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(palette.accent.color)
        .presentationDetents([.medium, .large])
        // The whole point: the article stays visible and live above the sheet,
        // so a slider is judged against the thing it is changing.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("readerControls")
    }

    // MARK: Themes

    private var themeSection: some View {
        card("Theme") {
            HStack(spacing: 8) {
                ForEach(ReaderTheme.allCases) { theme in
                    themeSwatch(theme)
                }
            }
        }
    }

    private func themeSwatch(_ theme: ReaderTheme) -> some View {
        var preview = reader.settings
        preview.theme = theme
        let colours = preview.palette
        let selected = reader.settings.theme == theme
        return Button {
            Haptics.shared.fire(.suggestionPick)
            reader.settings.theme = theme
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(colours.background.color)
                    if theme == .custom {
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(colours.text.color)
                    } else {
                        Text("Aa")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(colours.text.color)
                    }
                }
                .frame(height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            selected ? palette.accent.color : colours.border.color,
                            lineWidth: selected ? 2 : 0.5)
                }
                Text(theme.displayName)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? palette.accent.color : .secondary)
            }
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityLabel("\(theme.displayName) theme")
        .accessibilityIdentifier("readerTheme-\(theme.rawValue)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The colour tool from #0088F, reused rather than reimplemented: the same
    /// wheel, brightness track, HSB/RGB sliders and hex entry that pick a space
    /// accent pick a reader background.
    private var customColourSection: some View {
        card("Custom colours") {
            VStack(spacing: 0) {
                colourRow("Background", $reader.settings.customBackground, "readerCustomBackground")
                Divider().padding(.leading, 40)
                colourRow("Text", $reader.settings.customText, "readerCustomText")
                Divider().padding(.leading, 40)
                colourRow("Links", $reader.settings.customLink, "readerCustomLink")
            }
        }
    }

    private func colourRow(_ title: String, _ binding: Binding<ZenColor>, _ identifier: String)
        -> some View
    {
        NavigationLink {
            ReaderColourScreen(title: title, color: binding, recents: recents)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(binding.wrappedValue.color)
                    .frame(width: 28, height: 28)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(palette.border.color, lineWidth: 0.5)
                    }
                Text(title)
                Spacer()
                Text(binding.wrappedValue.hexString)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        }
        .tint(.primary)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Type

    private var faceSection: some View {
        card("Typeface") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReaderFont.allCases) { font in
                        faceChip(font)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    private func faceChip(_ font: ReaderFont) -> some View {
        let selected = reader.settings.font == font
        return Button {
            Haptics.shared.fire(.suggestionPick)
            reader.settings.font = font
        } label: {
            VStack(spacing: 2) {
                Text("Ag")
                    .font(.system(size: 20, weight: .medium, design: specimenDesign(font)))
                Text(font.displayName)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? palette.accent.color : Color.primary)
            .frame(width: 62, height: 52)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? palette.accent.withAlpha(0.14).color : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        selected ? palette.accent.color : palette.border.color,
                        lineWidth: selected ? 1.5 : 0.5)
            }
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityLabel(font.displayName)
        .accessibilityIdentifier("readerFont-\(font.rawValue)")
    }

    /// SwiftUI has four system designs and we offer nine faces, so the specimen
    /// is an approximation of the *kind* of type rather than the face itself —
    /// enough to tell a serif chip from a rounded one at a glance.
    private func specimenDesign(_ font: ReaderFont) -> Font.Design {
        switch font {
        case .systemMono: return .monospaced
        case .systemRounded: return .rounded
        default: return font.isSerif ? .serif : .default
        }
    }

    private var sizeSection: some View {
        card("Size") {
            HStack(spacing: 12) {
                Text("A").font(.system(size: 13))
                Slider(
                    value: $reader.settings.fontSize, in: ReaderSettings.fontSizeRange, step: 1
                )
                .accessibilityIdentifier("readerFontSize")
                Text("A").font(.system(size: 22))
                Text("\(Int(reader.settings.fontSize))")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
            }
        }
    }

    private var rhythmSection: some View {
        card("Spacing") {
            VStack(spacing: 10) {
                slider(
                    "Line height", value: $reader.settings.lineHeight,
                    range: ReaderSettings.lineHeightRange, step: 0.05,
                    readout: String(format: "%.2f", reader.settings.lineHeight),
                    identifier: "readerLineHeight")
                slider(
                    "Letter spacing", value: $reader.settings.letterSpacing,
                    range: ReaderSettings.letterSpacingRange, step: 0.005,
                    readout: String(format: "%.3fem", reader.settings.letterSpacing),
                    identifier: "readerLetterSpacing")
                slider(
                    "Paragraph gap", value: $reader.settings.paragraphSpacing,
                    range: ReaderSettings.paragraphSpacingRange, step: 0.1,
                    readout: String(format: "%.1fem", reader.settings.paragraphSpacing),
                    identifier: "readerParagraphSpacing")
            }
        }
    }

    // MARK: Measure

    private var measureSection: some View {
        card("Column width") {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    widthPreset("Narrow", ReaderSettings.narrowWidth)
                    widthPreset("Medium", ReaderSettings.mediumWidth)
                    widthPreset("Wide", ReaderSettings.wideWidth)
                }
                slider(
                    "Measure", value: $reader.settings.contentWidth,
                    range: ReaderSettings.contentWidthRange, step: 10,
                    readout: "\(Int(reader.settings.contentWidth))pt",
                    identifier: "readerContentWidth")
            }
        }
    }

    private func widthPreset(_ title: String, _ width: Double) -> some View {
        let selected = abs(reader.settings.contentWidth - width) < 1
        return Button {
            Haptics.shared.fire(.suggestionPick)
            reader.settings.contentWidth = width
        } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.accent.color : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? palette.accent.withAlpha(0.14).color : Color.clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            selected ? palette.accent.color : palette.border.color,
                            lineWidth: selected ? 1.5 : 0.5)
                }
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityIdentifier("readerWidth-\(title.lowercased())")
    }

    // MARK: Alignment

    private var alignmentSection: some View {
        card("Alignment") {
            VStack(spacing: 8) {
                Picker("Alignment", selection: $reader.settings.alignment) {
                    ForEach(ReaderAlignment.allCases) { alignment in
                        Text(alignment.displayName).tag(alignment)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("readerAlignment")

                Toggle("Hyphenate", isOn: $reader.settings.hyphenation)
                    .font(.system(size: 14))
                    .disabled(reader.settings.alignment != .justified)
                    .accessibilityIdentifier("readerHyphenation")

                Text(
                    reader.settings.alignment == .justified
                        ? "Justified text on a narrow column needs hyphenation, or the "
                            + "word spacing opens into rivers."
                        : "Hyphenation applies to justified text only — a ragged edge "
                            + "and broken words is the worst of both."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Dim

    private var dimSection: some View {
        card("Brightness") {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: "sun.max.fill").font(.system(size: 13))
                    Slider(value: $reader.settings.dim, in: ReaderSettings.dimRange)
                        .accessibilityIdentifier("readerDim")
                    Image(systemName: "moon.fill").font(.system(size: 13))
                }
                Text(
                    "Dims the article only, without touching the screen brightness the "
                        + "rest of the phone uses.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Page

    private var pageSection: some View {
        card("Page") {
            VStack(spacing: 8) {
                Toggle("Images", isOn: $reader.settings.showImages)
                    .font(.system(size: 14))
                    .accessibilityIdentifier("readerImages")
                Toggle("Drop cap", isOn: $reader.settings.dropCaps)
                    .font(.system(size: 14))
                    .accessibilityIdentifier("readerDropCaps")
            }
        }
    }

    // MARK: Voice

    private var voiceSection: some View {
        card("Read aloud") {
            slider(
                "Speed", value: $reader.settings.speechRate,
                range: ReaderSettings.speechRateRange, step: 0.01,
                readout: String(format: "%.2f×", reader.settings.speechRate / 0.5),
                identifier: "readerSpeechRate")
        }
    }

    // MARK: This site

    private var siteSection: some View {
        card("This site") {
            VStack(alignment: .leading, spacing: 10) {
                Text(siteExplanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button("Use my defaults") {
                        Haptics.shared.fire(.tabRestore)
                        reader.useGlobalDefaults()
                    }
                    .disabled(!reader.hasSiteOverride)
                    .accessibilityIdentifier("readerUseDefaults")

                    Spacer()

                    Button("Make these my defaults") {
                        Haptics.shared.fire(.bookmarkAdd)
                        state.settings.readerDefaults = reader.adoptAsDefaults()
                    }
                    .accessibilityIdentifier("readerAdoptDefaults")
                }
                .font(.system(size: 13, weight: .medium))
                .buttonStyle(.borderless)
            }
        }
    }

    private var siteExplanation: String {
        guard let site = reader.siteKey else {
            return "There is no site to remember these against."
        }
        return reader.hasSiteOverride
            ? "Remembered for \(site). Other sites follow your defaults."
            : "\(site) is following your defaults. Change anything above and it will be "
                + "remembered for this site."
    }

    // MARK: Chrome

    private func card<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.inputBG.color)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.border.color, lineWidth: 0.5)
        }
    }

    private func slider(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
        readout: String, identifier: String
    ) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(readout)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - One colour, picked

/// The accent picker's own screen, retitled. `ZenColorPicker` is the colour
/// tool from #0088F verbatim — wheel, brightness track, HSB and RGB sliders,
/// validated hex entry, recents — and the system picker is offered under it for
/// the eyedropper, exactly as `AccentPickerScreen` does for a space accent.
private struct ReaderColourScreen: View {
    let title: String
    @Binding var color: ZenColor
    @ObservedObject var recents: RecentColorsStore
    @State private var systemColor: Color = .accentColor
    @State private var initial: ZenColor?

    var body: some View {
        ScrollView {
            ZenColorPicker(color: $color, recents: recents)
                .padding(20)

            VStack(alignment: .leading, spacing: 6) {
                ColorPicker("System picker", selection: $systemColor, supportsOpacity: false)
                    .onChange(of: systemColor) { _, new in
                        guard let converted = ZenColor(new) else { return }
                        color = converted
                    }
                Text("Includes the eyedropper and your saved system colours.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if initial == nil { initial = color }
            systemColor = color.color
        }
        .onDisappear {
            // Destinations, not the journey — the recents row is no use full of
            // every colour a drag passed through.
            if color != initial { recents.record(color) }
        }
    }
}
