//  FindBar.swift
//  Find in page, on WKWebView's own find API (iOS 16+).

import SwiftUI
import WebKit

struct FindBar: View {
    @ObservedObject var state: BrowserState
    let pool: WebViewPool
    @Environment(\.zenPalette) private var palette
    @FocusState private var focused: Bool
    @State private var matchCount: Int?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text.withAlpha(0.5).color)

            TextField("Find in page", text: $state.findInPageQuery)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { find(forward: true) }

            if let matchCount {
                Text(matchCount == 0 ? "None" : "\(matchCount)")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.text.withAlpha(0.5).color)
                    .monospacedDigit()
            }

            Button { find(forward: false) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Previous match")
            Button { find(forward: true) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Next match")
            Button {
                state.isFindBarVisible = false
                state.findInPageQuery = ""
                matchCount = nil
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close find bar")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(palette.text.withAlpha(0.7).color)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .zenSurface(palette, radius: ZenMetrics.rowRadius, elevated: true)
        .onAppear { focused = true }
    }

    private func find(forward: Bool) {
        guard let tabID = state.activeTabID, let webView = pool.existing(for: tabID),
            !state.findInPageQuery.isEmpty
        else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(state.findInPageQuery, configuration: configuration) { result in
            // WKFindResult only reports found/not-found, not a match count.
            matchCount = result.matchFound ? nil : 0
        }
    }
}
