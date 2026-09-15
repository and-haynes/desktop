//  NewTabPage.swift
//  The start page. `about:blank` would render as a white slab fighting the
//  space gradient, so an empty tab shows the space's own identity instead,
//  with its essentials as shortcuts.

import SwiftUI

struct NewTabPage: View {
    @ObservedObject var state: BrowserState
    let space: Space
    @Environment(\.zenPalette) private var palette

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            VStack(spacing: 6) {
                SpaceIconView(space: space, size: 34)
                    .foregroundStyle(palette.text.color)
                // Zen's branding wordmark is set in Junicode, a serif; we do not
                // ship the font, so the nearest system serif stands in.
                Text(space.name)
                    .font(.system(size: 34, weight: .regular, design: .serif))
                    .foregroundStyle(palette.text.color)
            }

            Button {
                state.omniboxText = ""
                state.isOmniboxOpen = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: state.settings.searchEngine.symbol)
                    Text("Search or enter address")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 15))
                .foregroundStyle(palette.text.withAlpha(0.55).color)
                .padding(.horizontal, 16)
                .frame(height: 46)
                .frame(maxWidth: 420)
                .zenSurface(palette, radius: ZenMetrics.rowRadius)
            }
            .buttonStyle(ZenPressStyle(pressedScale: 0.99))

            if !state.essentials.isEmpty {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(state.essentials.prefix(8)) { tab in
                        Button {
                            state.select(tab.id)
                        } label: {
                            VStack(spacing: 6) {
                                FaviconView(tab: tab, size: 24)
                                    .frame(width: 52, height: 52)
                                    .background {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(
                                                palette.isDark
                                                    ? Color.white.opacity(0.10)
                                                    : Color.black.opacity(0.07))
                                    }
                                Text(tab.displayTitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(palette.text.withAlpha(0.6).color)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(ZenPressStyle())
                    }
                }
                .frame(maxWidth: 420)
            }

            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
