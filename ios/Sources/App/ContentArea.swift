//  ContentArea.swift
//  The page surface: one web view, or two in split, or the start page.
//
//  Every tab that has ever been selected keeps its WKWebView in the pool and
//  its representable in the hierarchy (hidden), so switching tabs does not
//  reload the page. Unloaded tabs have no view at all.

import SwiftUI

struct ContentArea: View {
    @ObservedObject var state: BrowserState
    let space: Space
    let pool: WebViewPool
    /// Scroll-view insets for the page. Non-zero when the page is allowed to
    /// run under the Dynamic Island because the status bar is hidden.
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0
    @Environment(\.zenPalette) private var palette

    var body: some View {
        Group {
            if let secondary = state.splitSecondaryTabID, let primary = state.activeTabID,
                primary != secondary
            {
                SplitContainer(
                    primaryID: primary, secondaryID: secondary, state: state
                ) { id in
                    pane(id)
                }
            } else if let tab = state.activeTab {
                pane(tab.id)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: ZenMetrics.contentRadius, style: .continuous))
            } else {
                NewTabPage(state: state, space: space)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 1), value: state.splitSecondaryTabID)
    }

    @ViewBuilder
    private func pane(_ tabID: UUID) -> some View {
        if let tab = state.tab(id: tabID) {
            ZStack {
                if tab.isNewTabPage {
                    NewTabPage(state: state, space: space)
                } else {
                    WebView(
                        tab: tab, space: space, state: state, pool: pool,
                        topContentInset: topContentInset,
                        bottomContentInset: bottomContentInset
                    )
                    .background(palette.mainBrowserBackground.color)
                    // Over the top rather than instead of: the web view stays
                    // alive underneath, so Retry is a reload and not a rebuild.
                    if let failure = tab.loadFailure {
                        ErrorPageView(failure: failure) {
                            // Clearing lastRequestedURL is what lets the same
                            // URL be attempted again; reload() has nothing
                            // committed to reload after a failed provisional
                            // load.
                            pool.existing(for: tab.id)?.lastRequestedURL = nil
                            state.updateTab(tab.id) { $0.loadFailure = nil }
                        } onNavigate: { url in
                            state.updateTab(tab.id) {
                                $0.url = url
                                $0.loadFailure = nil
                                $0.title = ""
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
            // A tab's identity must be stable or SwiftUI recycles the
            // representable across tabs and you get the wrong page.
            .id(tab.id)
        }
    }
}
