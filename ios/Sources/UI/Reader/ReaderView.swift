//  ReaderView.swift
//  The reader, with its chrome: where you are in the article, the way to the
//  appearance panel, and the transport for reading it aloud (#008BC).
//
//  The chrome is deliberately thin at both ends and gets out of the way in the
//  middle — a reading view whose furniture competes with the type has missed
//  the point. Two pieces carry the state: a hairline progress bar under the top
//  bar, and the percentage beside the site name. Everything else is a control.
//
//  The dim is a black overlay *inside the app* rather than a screen-brightness
//  change, which is what every reading app does and for a good reason: it is
//  per-article, it does not touch what the phone does everywhere else, and it
//  comes off the moment you leave. It cannot reach full opacity (see
//  `ReaderSettings.dimRange`) because a control that can hide itself is a trap.

import SwiftUI

struct ReaderView: View {
    @ObservedObject var state: BrowserState
    @ObservedObject var reader: ReaderController
    let space: Space
    let onClose: () -> Void
    let onOpenLink: (URL) -> Void

    @Environment(\.zenPalette) private var palette

    private var readerPalette: ReaderPalette { reader.settings.palette }

    /// The chrome's own scheme follows the *page*, not the browser: light
    /// controls over a sepia article would be unreadable however the rest of
    /// Zen is themed.
    private var chromeText: Color { readerPalette.text.color }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                readerPalette.background.color
                    .ignoresSafeArea()

                ReaderWebView(controller: reader, space: space, onOpenLink: onOpenLink)
                    .ignoresSafeArea()

                // Never over the chrome, and never able to swallow a tap.
                Color.black
                    .opacity(reader.settings.dim)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                chrome
            }
            .onAppear { updateInsets(proxy) }
            .onChange(of: proxy.safeAreaInsets.top) { _, _ in updateInsets(proxy) }
            .onChange(of: reader.isReadAloudVisible) { _, _ in updateInsets(proxy) }
        }
        .transition(.opacity)
        // No `accessibilityIdentifier` on this container, and none on the two
        // bars below either. An accessibility modifier on a SwiftUI container
        // is applied to *every element inside it*, so one here renames the
        // close button, the appearance button and all three pill buttons to
        // "readerView" — they are then unreachable by their own identifiers,
        // while still being perfectly visible on screen. That is exactly how
        // this feature's UI tests failed twice before the hierarchy was dumped.
    }

    /// The page has to start below the top bar and end above the pill, and
    /// those move — the transport appearing is 56pt the last paragraph would
    /// otherwise sit under.
    private func updateInsets(_ proxy: GeometryProxy) {
        reader.setInsets(
            ReaderInsets(
                top: Double(proxy.safeAreaInsets.top) + 58,
                bottom: Double(proxy.safeAreaInsets.bottom)
                    + (reader.isReadAloudVisible ? 132 : 76)))
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            if reader.isReadAloudVisible {
                ReaderTransport(reader: reader)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            bottomPill
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: reader.isReadAloudVisible)
    }

    // MARK: Top

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                closeButton
                Spacer(minLength: 4)
                titleBlock
                Spacer(minLength: 4)
                appearanceButton
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            progressBar
        }
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(readerPalette.background.withAlpha(0.72).color)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var closeButton: some View {
        Button {
            Haptics.shared.fire(.glanceClose)
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(chromeText.opacity(0.75))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityLabel("Close reader")
        .accessibilityIdentifier("readerClose")
    }

    private var titleBlock: some View {
        VStack(spacing: 1) {
            Text(headerLine)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chromeText.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(subheaderLine)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(readerPalette.secondary.color)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("readerProgress")
    }

    private var headerLine: String {
        guard let article = reader.article else { return "Reader" }
        if !article.siteName.isEmpty { return article.siteName }
        if let host = article.url.map(URLDetector.prettyHost), !host.isEmpty { return host }
        return article.title
    }

    private var subheaderLine: String {
        guard let article = reader.article else { return "" }
        return "\(article.readingTimeLabel) · \(Int((reader.progress * 100).rounded()))%"
    }

    /// A hairline rather than a bar. The percentage above it is the number;
    /// this is the shape of how far in you are, which is the thing you take in
    /// without reading.
    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                readerPalette.border.color
                Rectangle()
                    .fill(readerPalette.link.color)
                    .frame(width: max(0, proxy.size.width * reader.progress))
            }
        }
        .frame(height: 2)
        .animation(.linear(duration: 0.12), value: reader.progress)
    }

    private var appearanceButton: some View {
        Button {
            Haptics.shared.fire(.layoutChange)
            reader.isPanelPresented = true
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(chromeText.opacity(0.85))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityLabel("Reader appearance")
        .accessibilityIdentifier("readerAppearance")
        .sheet(isPresented: $reader.isPanelPresented) {
            ReaderControlsPanel(reader: reader, state: state)
                .environment(\.zenPalette, palette)
        }
    }

    // MARK: Bottom

    private var bottomPill: some View {
        HStack(spacing: 2) {
            pillButton(
                "speaker.wave.2", label: "Read aloud", identifier: "readerReadAloud",
                active: reader.isReadAloudVisible
            ) {
                Haptics.shared.fire(.layoutChange)
                reader.isReadAloudVisible.toggle()
                if !reader.isReadAloudVisible { reader.speech.stop() }
            }
            pillButton(
                "textformat", label: "Appearance", identifier: "readerAppearancePill",
                active: reader.isPanelPresented
            ) {
                Haptics.shared.fire(.layoutChange)
                reader.isPanelPresented = true
            }
            pillButton(
                "doc.richtext", label: "Show original", identifier: "readerShowOriginal",
                active: false
            ) {
                Haptics.shared.fire(.glanceClose)
                onClose()
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 46)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay { Capsule().fill(readerPalette.background.withAlpha(0.6).color) }
                .overlay { Capsule().strokeBorder(readerPalette.border.color, lineWidth: 0.5) }
        }
        .clipShape(Capsule())
        .zenBigShadow()
    }

    private func pillButton(
        _ symbol: String, label: String, identifier: String, active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? readerPalette.link.color : chromeText.opacity(0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(ZenPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Read aloud

/// Play, skip and stop, plus where the voice has got to.
///
/// "Sentence 12 of 340" rather than a time remaining: the synthesizer will not
/// say how long it has left, and a made-up estimate that drifts is worse than a
/// count that is simply true.
private struct ReaderTransport: View {
    @ObservedObject var reader: ReaderController
    @ObservedObject private var speech: ReaderSpeech

    init(reader: ReaderController) {
        self.reader = reader
        self.speech = reader.speech
    }

    private var palette: ReaderPalette { reader.settings.palette }

    var body: some View {
        HStack(spacing: 4) {
            transportButton("backward.end.fill", "Previous sentence", "readerPrevious") {
                speech.previous()
            }
            transportButton(
                speech.isSpeaking && !speech.isPaused ? "pause.fill" : "play.fill",
                speech.isSpeaking && !speech.isPaused ? "Pause" : "Play", "readerPlayPause",
                prominent: true
            ) {
                speech.toggle()
            }
            transportButton("forward.end.fill", "Next sentence", "readerNext") {
                speech.next()
            }
            Text(positionLabel)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.secondary.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
            transportButton("xmark", "Stop reading", "readerStop") {
                speech.stop()
                reader.isReadAloudVisible = false
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay { Capsule().fill(palette.background.withAlpha(0.6).color) }
                .overlay { Capsule().strokeBorder(palette.border.color, lineWidth: 0.5) }
        }
        .clipShape(Capsule())
        .zenBigShadow()
        // Deliberately unidentified — see the note in `ReaderView.body`.
    }

    private var positionLabel: String {
        guard speech.hasContent else { return "Nothing to read" }
        guard let index = speech.currentIndex else { return "\(speech.sentenceCount) sentences" }
        return "\(index + 1) of \(speech.sentenceCount)"
    }

    private func transportButton(
        _ symbol: String, _ label: String, _ identifier: String, prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.shared.fire(.tabSelect)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 16 : 13, weight: .semibold))
                .foregroundStyle(
                    prominent ? palette.link.color : palette.text.withAlpha(0.8).color
                )
                .frame(width: prominent ? 40 : 34, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(ZenPressStyle())
        .disabled(!speech.hasContent)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
