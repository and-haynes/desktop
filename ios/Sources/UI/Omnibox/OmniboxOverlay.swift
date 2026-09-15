//  OmniboxOverlay.swift
//  Zen's floating centered search box.
//
//  `#urlbar[open][zen-floating-urlbar="true"]` is centered (`left: 50%;
//  translate: -50% 0`), `min(90%, 62rem)` wide, 62px tall, 12px radius, with a
//  very large soft shadow (`0 30px 140px -15px`) and a hairline outline. The
//  results list is capped at 252px.

import SwiftUI

struct OmniboxOverlay: View {
    @ObservedObject var state: BrowserState
    @Environment(\.zenPalette) private var palette
    @StateObject private var engine = SuggestionEngine()
    @State private var isFieldFocused = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            // The dim behind the box. Upstream scales and dims the page; here
            // the box is modal, so a plain scrim reads better.
            Color.black
                .opacity(appeared ? (palette.isDark ? 0.55 : 0.28) : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                field
                if !engine.suggestions.isEmpty {
                    Divider().overlay(palette.border.color)
                    suggestionList
                }
            }
            .frame(
                maxWidth: min(
                    ZenMetrics.omniboxMaxWidth,
                    UIScreen.main.bounds.width * ZenMetrics.omniboxWidthFraction))
            .zenSurface(palette, radius: ZenMetrics.omniboxRadius, elevated: true)
            .scaleEffect(appeared ? 1 : 0.97)
            .opacity(appeared ? 1 : 0)
            .padding(.horizontal, 12)
        }
        .onAppear {
            Haptics.shared.prepare([.urlCommit, .suggestionPick, .omniboxClose])
            engine.update(query: state.omniboxText, state: state)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { appeared = true }
            // The field must not steal focus before the sheet has settled, or
            // the keyboard animates in from the wrong place.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isFieldFocused = true }
        }
        .onChange(of: state.omniboxText) { _, new in
            engine.update(query: new, state: state)
        }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: state.settings.searchEngine.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.accent.color)

            OmniboxTextField(
                text: $state.omniboxText,
                placeholder: "Search or enter address",
                textColor: palette.text.uiColor,
                tintColor: palette.accent.uiColor,
                isFocused: isFieldFocused
            ) {
                commit(state.omniboxText)
            }

            if !state.omniboxText.isEmpty {
                Button {
                    state.omniboxText = ""
                    isFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.text.withAlpha(0.35).color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: ZenMetrics.omniboxFloatingHeight)
    }

    // MARK: Suggestions

    private var suggestionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(engine.suggestions) { suggestion in
                    SuggestionRow(suggestion: suggestion) { select(suggestion) }
                }
            }
        }
        .frame(maxHeight: ZenMetrics.suggestionsMaxHeight)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Actions

    private func select(_ suggestion: Suggestion) {
        switch suggestion.kind {
        case .topHit:
            commit(state.omniboxText)
        case .history(let url), .goToHost(let url), .localService(let url):
            Haptics.shared.fire(.suggestionPick)
            navigate(to: url)
        case .searchTerm:
            Haptics.shared.fire(.suggestionPick)
            navigate(to: state.settings.searchEngine.searchURL(for: suggestion.title))
        case .action(let action):
            Haptics.shared.fire(.suggestionPick)
            close(silent: true)
            perform(action)
        }
    }

    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            close()
            return
        }
        Haptics.shared.fire(.urlCommit)
        // A bare word that *is* an alias you gave something on this network
        // goes straight there (#0089C). Exact, whole-string, case-insensitive
        // only: anything looser and typing `mail` would stop searching for
        // mail, which is the mistake the single-word rule already refuses to
        // make in the other direction.
        if let service = state.localServices.exactMatch(trimmed) {
            navigate(to: service.url)
            return
        }
        navigate(
            to: URLDetector.resolve(
                trimmed, engine: state.settings.searchEngine,
                knownHosts: state.knownSingleLabelHosts))
    }

    private func navigate(to url: URL) {
        // The target is the pane whose bar opened this, not necessarily the
        // active tab.
        if let tabID = state.omniboxTargetTab?.id {
            state.updateTab(tabID) { tab in
                tab.url = url
                tab.title = ""
                tab.scrollY = 0
            }
        } else {
            state.newTab(url: url)
        }
        close(silent: true)
    }

    /// `silent` where the close is the tail of something that already spoke —
    /// a commit or a picked suggestion. Two taps back to back for one action
    /// reads as a stutter, not as feedback.
    private func close(silent: Bool = false) {
        if !silent { Haptics.shared.fire(.omniboxClose) }
        state.omniboxTargetTabID = nil
        isFieldFocused = false
        engine.clear()
        withAnimation(.easeOut(duration: 0.18)) {
            appeared = false
            state.isOmniboxOpen = false
        }
        state.omniboxText = ""
    }

    private func perform(_ action: OmniboxAction) {
        switch action {
        case .toggleCompactMode: state.settings.compactModeEnabled.toggle()
        case .newSplitView, .unsplitView:
            Haptics.shared.fire(state.isSplitActive ? .splitExit : .splitEnter)
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) { state.toggleSplit() }
        case .newSpace: state.isSettingsPresented = true
        case .copyCurrentURL: UIPasteboard.general.url = state.activeTab?.url
        case .nextSpace: withAnimation { state.cycleSpace(by: 1) }
        case .previousSpace: withAnimation { state.cycleSpace(by: -1) }
        case .closeTab:
            if let tabID = state.activeTabID {
                Haptics.shared.fire(.tabClose)
                state.closeTab(tabID)
            }
        case .duplicateTab:
            if let tab = state.activeTab {
                Haptics.shared.fire(.tabOpen)
                state.newTab(url: tab.url)
            }
        case .reloadTab: NotificationCenter.default.post(name: .zenReloadActiveTab, object: nil)
        case .findInPage: state.isFindBarVisible = true
        case .toggleDesktopSite: state.settings.preferDesktopSite.toggle()
        case .openSettings: state.isSettingsPresented = true
        case .openHistory: state.isHistorySheetPresented = true
        }
    }
}

/// `.urlbarView-row` — favicon in a small inset swatch, a 14px/500 title and a
/// dimmer second line.
struct SuggestionRow: View {
    let suggestion: Suggestion
    let action: () -> Void
    @Environment(\.zenPalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZenMetrics.suggestionIconGap) {
                Image(systemName: suggestion.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.text.withAlpha(0.7).color)
                    .frame(width: 26, height: 26)
                    .background {
                        RoundedRectangle(
                            cornerRadius: ZenMetrics.suggestionIconRadius, style: .continuous
                        )
                        .fill(palette.toolbarElementHoverBG.color)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.text.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(suggestion.subtitle)
                        .font(.system(size: 12))
                        // `.urlbarView-url { color: light-dark(#4f4f4f, #aaa) }`
                        .foregroundStyle(
                            (palette.isDark
                                ? ZenColor(hex: "#aaaaaa")! : ZenColor(hex: "#4f4f4f")!).color
                        )
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ZenMetrics.suggestionRowPaddingInline)
            .padding(.vertical, ZenMetrics.suggestionRowPaddingBlock)
            .contentShape(Rectangle())
        }
        .buttonStyle(SuggestionRowStyle(palette: palette))
    }
}

/// The selected/hover wash: `color-mix(in srgb, var(--zen-branding-bg-reverse)
/// 5%, transparent 95%)`.
private struct SuggestionRowStyle: ButtonStyle {
    let palette: ZenPalette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? palette.brandingBGReverse.withAlpha(0.06).color : .clear)
    }
}
