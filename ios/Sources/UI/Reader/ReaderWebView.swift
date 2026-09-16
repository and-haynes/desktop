//  ReaderWebView.swift
//  The reader's own web view: a local document, styled live, that never
//  navigates (#008BC).
//
//  A second `WKWebView` over the page rather than a takeover of the page's own,
//  for one reason that decides everything else: **leaving the reader has to put
//  you back exactly where you were.** The article's web view is untouched
//  underneath — same scroll offset, same history, same session — so exiting is
//  removing a layer rather than restoring a state, which is the version that
//  cannot go wrong.
//
//  It loads once and never again. Every appearance control is a custom property
//  set through `evaluateJavaScript`, because a reload would lose your place in
//  a long article, and an appearance control that scrolls you back to the top is
//  one you use once and then stop touching.

import SwiftUI
import WebKit

struct ReaderWebView: UIViewRepresentable {
    @ObservedObject var controller: ReaderController
    /// The space's data store, so an image the article loads arrives with the
    /// same cookies it did on the page it came from.
    let space: Space
    let onOpenLink: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onOpenLink: onOpenLink)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebEngine.dataStore(for: space)
        configuration.applicationNameForUserAgent = "Zen/0.1"
        // The reader page's own inline script posts here. `.page` because that
        // is the world the document's own `<script>` runs in; there is nothing
        // of anyone else's in this web view to isolate it from.
        configuration.userContentController.add(
            controller, contentWorld: .page, name: ReaderTemplate.messageHandlerName)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.contentInsetAdjustmentBehavior = .never
        // The reader paints its own background; leaving this clear shows the
        // space gradient through the article for a frame on every scroll.
        view.isOpaque = true
        view.backgroundColor = controller.settings.palette.background.uiColor
        view.scrollView.backgroundColor = controller.settings.palette.background.uiColor
        view.allowsBackForwardNavigationGestures = false
        controller.webView = view

        if let document = controller.document() {
            view.loadHTMLString(document, baseURL: controller.article?.url)
        }
        return view
    }

    /// Deliberately almost empty. SwiftUI calls this on every published change
    /// — including every frame of a slider drag — and re-loading the document
    /// here would throw away the reader's scroll position sixty times a second.
    /// Styling goes through `ReaderController.applySettings`.
    func updateUIView(_ view: WKWebView, context: Context) {
        let background = controller.settings.palette.background.uiColor
        guard view.backgroundColor != background else { return }
        view.backgroundColor = background
        view.scrollView.backgroundColor = background
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        // The content controller holds the handler strongly; without this the
        // controller outlives every reader session that ever opened.
        view.configuration.userContentController.removeScriptMessageHandler(
            forName: ReaderTemplate.messageHandlerName, contentWorld: .page)
        view.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let controller: ReaderController
        private let onOpenLink: (URL) -> Void

        init(controller: ReaderController, onOpenLink: @escaping (URL) -> Void) {
            self.controller = controller
            self.onOpenLink = onOpenLink
        }

        /// A reader view is one document and stays one document. Tapping a link
        /// in an article means "go there", and going there means the browser —
        /// a second article rendered inside the reader with no address bar and
        /// no back gesture would be a trap.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                let url = navigationAction.request.url
            else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            onOpenLink(url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The document declares the settings inline, but the insets it was
            // rendered with may already be stale — the read-aloud bar can have
            // appeared while the page was loading.
            controller.applySettings()
        }
    }
}
