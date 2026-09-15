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
                    WebView(tab: tab, space: space, state: state, pool: pool)
                        .background(palette.mainBrowserBackground.color)
                }
            }
            // A tab's identity must be stable or SwiftUI recycles the
            // representable across tabs and you get the wrong page.
            .id(tab.id)
        }
    }
}
