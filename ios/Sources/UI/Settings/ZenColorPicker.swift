//  ZenColorPicker.swift
//  The colour tool behind a space's accent.
//
//  Zen's desktop gradient generator gives you a wheel and expects you to work
//  in it, so the graphical picker is the main surface here rather than a
//  system `ColorPicker` sheet — that one is offered as a secondary entry point
//  for people who want the eyedropper, but it is not where the feature lives.
//
//  Everything below writes the same `ZenColor`, which is what zen-theme.css's
//  derivation chain consumes, so no path here can produce an accent the rest of
//  the app cannot theme from.

import SwiftUI

struct ZenColorPicker: View {
    @Binding var color: ZenColor
    /// The space's existing gradient stops, offered as one-tap targets.
    var gradientStops: [ZenColor] = []
    @ObservedObject var recents: RecentColorsStore

    @Environment(\.zenPalette) private var palette

    /// Hue and saturation live in the wheel, brightness in its own slider —
    /// splitting them keeps the wheel readable at low brightness, where an
    /// HSB square collapses to near-black.
    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1

    @State private var hexText = ""
    @State private var rgbText = ""
    @State private var hexError: String?
    @State private var rgbError: String?
    /// Guards the feedback loop between the sliders and the text fields.
    @State private var isSyncing = false

    /// Extra entry points a caller can switch off (the library lives on the
    /// experimental branch and injects itself here).
    var accessory: AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            wheelSection
            slidersSection
            textSection
            if let accessory { accessory }
            swatchSection
        }
        .onAppear { syncFromColor() }
        .onChange(of: color) { _, _ in
            guard !isSyncing else { return }
            syncFromColor()
        }
    }

    // MARK: Wheel

    private var wheelSection: some View {
        HStack(alignment: .center, spacing: 16) {
            ColorWheel(hue: $hue, saturation: $saturation, brightness: brightness)
                .frame(width: 168, height: 168)
                .onChange(of: hue) { _, _ in commitFromHSB() }
                .onChange(of: saturation) { _, _ in commitFromHSB() }
                .accessibilityLabel("Colour wheel")
                .accessibilityValue(
                    "Hue \(Int(hue * 360)) degrees, saturation \(Int(saturation * 100)) percent")

            VStack(spacing: 10) {
                BrightnessSlider(
                    hue: hue, saturation: saturation, brightness: $brightness
                )
                .frame(width: 30, height: 168)
                .onChange(of: brightness) { _, _ in commitFromHSB() }
                .accessibilityLabel("Brightness")
                .accessibilityValue("\(Int(brightness * 100)) percent")
            }

            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.color)
                    .frame(width: 56, height: 56)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(palette.borderContrast.color, lineWidth: 0.5)
                    }
                Text(ColorParsing.formatHex(color))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Sliders

    private var slidersSection: some View {
        VStack(spacing: 8) {
            numericSlider("H", value: $hue, range: 0...1, display: hue * 360, unit: "°") {
                commitFromHSB()
            }
            numericSlider(
                "S", value: $saturation, range: 0...1, display: saturation * 100, unit: "%"
            ) { commitFromHSB() }
            numericSlider(
                "B", value: $brightness, range: 0...1, display: brightness * 100, unit: "%"
            ) { commitFromHSB() }

            Divider().padding(.vertical, 2)

            rgbSlider("R", component: \.r)
            rgbSlider("G", component: \.g)
            rgbSlider("B", component: \.b)
        }
    }

    private func numericSlider(
        _ label: String, value: Binding<Double>, range: ClosedRange<Double>,
        display: Double, unit: String, onChange: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 14, alignment: .leading)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .onChange(of: value.wrappedValue) { _, _ in onChange() }
            Text("\(Int(display.rounded()))\(unit)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    /// RGB sliders write through the colour directly, then refresh HSB — the
    /// two representations must never drift apart.
    private func rgbSlider(_ label: String, component: WritableKeyPath<ZenColor, Double>)
        -> some View
    {
        let binding = Binding<Double>(
            get: { color[keyPath: component] * 255 },
            set: { newValue in
                var updated = color
                updated[keyPath: component] = min(max(newValue / 255, 0), 1)
                isSyncing = true
                color = updated
                syncFromColor()
                isSyncing = false
            })
        return HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 14, alignment: .leading)
                .foregroundStyle(.secondary)
            Slider(value: binding, in: 0...255)
            Text("\(Int(binding.wrappedValue.rounded()))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    // MARK: Text entry

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(
                title: "Hex", placeholder: "#5B6EE1", text: $hexText, error: hexError,
                identifier: "hexField"
            ) {
                switch ColorParsing.parseHex(hexText) {
                case .success(let parsed):
                    hexError = nil
                    apply(parsed)
                case .failure(let error):
                    hexError = error.errorDescription
                }
            }

            field(
                title: "RGB", placeholder: "91, 110, 225", text: $rgbText, error: rgbError,
                identifier: "rgbField"
            ) {
                switch ColorParsing.parseRGB(rgbText) {
                case .success(let parsed):
                    rgbError = nil
                    apply(parsed)
                case .failure(let error):
                    rgbError = error.errorDescription
                }
            }
        }
    }

    private func field(
        title: String, placeholder: String, text: Binding<String>, error: String?,
        identifier: String, onCommit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 34, alignment: .leading)
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: text)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .accessibilityIdentifier(identifier)
                    .onSubmit(onCommit)
                Button("Apply", action: onCommit)
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.borderless)
            }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(identifier)Error")
            }
        }
    }

    // MARK: Swatches

    private var swatchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !gradientStops.isEmpty {
                swatchRow(
                    "This space's gradient", colors: gradientStops, identifier: "gradientStops")
            }
            if !recents.colors.isEmpty {
                swatchRow("Recent", colors: recents.colors, identifier: "recentColors")
            }
        }
    }

    private func swatchRow(_ title: String, colors: [ZenColor], identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, swatch in
                        Button {
                            apply(swatch)
                        } label: {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Circle().strokeBorder(
                                        swatch.hexString == color.hexString
                                            ? Color.primary : palette.borderContrast.color,
                                        lineWidth: swatch.hexString == color.hexString ? 2 : 0.5)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(ColorParsing.formatHex(swatch))
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier(identifier)
        }
    }

    // MARK: Sync

    /// Apply a colour chosen by any route, and refresh every other control.
    func apply(_ newColor: ZenColor) {
        isSyncing = true
        color = newColor.withAlpha(1)
        syncFromColor()
        isSyncing = false
    }

    private func commitFromHSB() {
        guard !isSyncing else { return }
        isSyncing = true
        color = ZenColor(hue: hue, saturation: saturation, brightness: brightness)
        hexText = ColorParsing.formatHex(color)
        rgbText = ColorParsing.formatRGB(color)
        hexError = nil
        rgbError = nil
        isSyncing = false
    }

    private func syncFromColor() {
        let hsb = color.hsb
        // A fully desaturated or black colour has no meaningful hue; keeping
        // the previous one stops the wheel marker jumping to red when you drag
        // brightness to zero.
        if hsb.saturation > 0.001 { hue = hsb.hue }
        if hsb.brightness > 0.001 { saturation = hsb.saturation }
        brightness = hsb.brightness
        hexText = ColorParsing.formatHex(color)
        rgbText = ColorParsing.formatRGB(color)
        hexError = nil
        rgbError = nil
    }
}

// MARK: - Wheel

/// A hue/saturation wheel drawn with Canvas — hue around, saturation outward.
/// Brightness is applied as a dimming overlay rather than being baked into the
/// gradient, so dragging the brightness slider does not force a redraw of the
/// whole wheel.
struct ColorWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    let brightness: Double

    /// The conic ring is drawn from this many wedges; more is smoother and
    /// slower, and past about 120 the difference stops being visible.
    private let wedges = 120

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side / 2
            let centre = CGPoint(x: side / 2, y: side / 2)

            ZStack {
                Canvas { context, _ in
                    for index in 0..<wedges {
                        let start = Double(index) / Double(wedges)
                        let end = Double(index + 1) / Double(wedges)
                        var wedge = Path()
                        wedge.move(to: centre)
                        wedge.addArc(
                            center: centre, radius: radius,
                            startAngle: .degrees(start * 360 - 90.5),
                            endAngle: .degrees(end * 360 - 89.5), clockwise: false)
                        wedge.closeSubpath()
                        // Saturation falls off toward the centre, so each wedge
                        // is a radial gradient from white to the full hue.
                        context.fill(
                            wedge,
                            with: .radialGradient(
                                Gradient(colors: [
                                    .white,
                                    ZenColor(hue: start, saturation: 1, brightness: 1).color,
                                ]),
                                center: centre, startRadius: 0, endRadius: radius))
                    }
                }
                // Brightness as a dim, matching how the swatch will look.
                Circle().fill(.black).opacity(1 - brightness)

                Circle()
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)

                marker(radius: radius, centre: centre)
            }
            .frame(width: side, height: side)
            .clipShape(Circle())
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in update(from: value.location, centre: centre, radius: radius) }
            )
        }
    }

    private func marker(radius: CGFloat, centre: CGPoint) -> some View {
        let angle = hue * 2 * .pi - .pi / 2
        let distance = saturation * radius
        let position = CGPoint(
            x: centre.x + cos(angle) * distance,
            y: centre.y + sin(angle) * distance)
        return Circle()
            .strokeBorder(Color.white, lineWidth: 2)
            .background(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 3.5))
            .frame(width: 18, height: 18)
            .position(position)
            .allowsHitTesting(false)
    }

    private func update(from point: CGPoint, centre: CGPoint, radius: CGFloat) {
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        hue = angle / (2 * .pi)
        // Clamp rather than ignore drags outside the circle: the finger leaving
        // the wheel should pin saturation at 100%, not stop tracking.
        saturation = min(sqrt(dx * dx + dy * dy) / radius, 1)
    }
}

/// Vertical brightness track, tinted with the current hue and saturation.
struct BrightnessSlider: View {
    let hue: Double
    let saturation: Double
    @Binding var brightness: Double

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [
                        ZenColor(hue: hue, saturation: saturation, brightness: 1).color,
                        .black,
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .clipShape(Capsule())
                .overlay { Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5) }

                Capsule()
                    .fill(.white)
                    .frame(height: 4)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .padding(.horizontal, 2)
                    .offset(y: (1 - brightness) * (height - 4))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        brightness = 1 - min(max(value.location.y / height, 0), 1)
                    }
            )
        }
    }
}

// MARK: - Screen

/// The accent picker as a pushed screen, with the system picker offered as a
/// secondary route and the choice recorded in recents on the way out.
struct AccentPickerScreen: View {
    @Binding var color: ZenColor
    var gradientStops: [ZenColor] = []
    @ObservedObject var recents: RecentColorsStore
    /// Injected by the experimental branch's named-colour library.
    var accessory: AnyView?

    @Environment(\.dismiss) private var dismiss
    @State private var systemColor: Color = .accentColor
    @State private var initial: ZenColor?

    var body: some View {
        ScrollView {
            ZenColorPicker(
                color: $color, gradientStops: gradientStops, recents: recents,
                accessory: accessory
            )
            .padding(20)

            // Secondary entry point: the system picker brings the eyedropper
            // and the OS palette, which we are not going to reimplement.
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
        .navigationTitle("Accent")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if initial == nil { initial = color }
            systemColor = color.color
        }
        .onDisappear {
            // Only record a colour actually settled on, not every intermediate
            // drag — the recents row is for destinations, not the journey.
            if color != initial { recents.record(color) }
        }
    }
}

extension ZenColor {
    /// Best-effort conversion from a SwiftUI `Color`, for the system picker.
    /// Returns nil for colours with no concrete sRGB components (a dynamic
    /// system colour outside a rendering context).
    init?(_ color: Color) {
        let ui = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        self.init(r: Double(r), g: Double(g), b: Double(b), a: 1)
    }
}
