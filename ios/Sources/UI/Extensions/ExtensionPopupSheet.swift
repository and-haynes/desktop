//  ExtensionPopupSheet.swift
//  An extension's action popup, in a sheet.
//
//  On desktop this is a popover hanging off the toolbar button. On a phone
//  there is no room for one: a popup is an arbitrary HTML document an
//  extension author sized for a 320pt-wide panel, and a popover over a 390pt
//  screen is a sheet with extra steps. So it is a sheet with detents, which is
//  what every other panel in Zen does.
//
//  The web view is **WebKit's**, not ours. `WKWebExtensionAction.popupWebView`
//  is already configured with the extension's own controller, world and origin
//  — a web view we built and pointed at the popup URL would have none of that
//  and `browser.runtime` would be undefined inside it. So this wraps the view
//  it is given and adds nothing.

import SwiftUI
import WebKit

struct ExtensionPopupSheet: View {
    let request: ExtensionPopupRequest
    @ObservedObject var host: ExtensionHost
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette

    var body: some View {
        NavigationStack {
            ExtensionPopupWebView(webView: request.webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(request.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(palette.accent.color)
        .accessibilityIdentifier("extensionPopupSheet")
        // The sheet can go away by drag as well as by the button, and WebKit
        // has to be told either way or the action keeps thinking its popup is
        // on screen.
        .onDisappear { host.dismissPopup() }
    }
}

/// Puts an existing `WKWebView` into SwiftUI without owning it.
private struct ExtensionPopupWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: ()) {
        // Deliberately nothing: WebKit owns this view, and tearing it down here
        // would break the next time the same action is tapped.
        view.removeFromSuperview()
    }
}
