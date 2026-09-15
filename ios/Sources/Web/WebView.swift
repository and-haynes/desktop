//  WebView.swift
//  The SwiftUI bridge to a pooled WKWebView, plus the navigation delegate that
//  feeds title/URL/progress/favicon back into BrowserState.

import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let tab: Tab
    let space: Space
    @ObservedObject var state: BrowserState
    let pool: WebViewPool
    /// Applied to the scroll view directly. `contentInsetAdjustmentBehavior`
    /// stays `.never`, so this is the only thing moving the page — which is
    /// what keeps scroll-to-top landing in the right place where the page runs
    /// under the top safe area.
    var topContentInset: CGFloat = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, pool: pool)
    }

    func makeUIView(context: Context) -> ZenWebView {
        let view = pool.webView(for: tab, space: space, desktop: state.settings.preferDesktopSite)
        attach(view, context: context)
        if view.url == nil && !tab.isNewTabPage {
            context.coordinator.load(tab.url, in: view)
        }
        return view
    }

    func updateUIView(_ view: ZenWebView, context: Context) {
        attach(view, context: context)
        // Only drive a navigation when the model's URL genuinely diverged from
        // what the view is showing — otherwise every SwiftUI update would
        // reload the page.
        //
        // `lastRequestedURL` is what stops a *failed* load retrying forever.
        // A refused connection leaves `view.url` on the previous page, so the
        // comparison below stays true indefinitely and would re-request on
        // every update, clearing the error each time.
        guard !tab.isNewTabPage, view.url?.absoluteString != tab.url.absoluteString,
            view.lastRequestedURL?.absoluteString != tab.url.absoluteString,
            !view.isLoading
        else { return }
        context.coordinator.load(tab.url, in: view)
    }

    private func attach(_ view: ZenWebView, context: Context) {
        context.coordinator.tabID = tab.id
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.scrollView.delegate = context.coordinator
        applyInsets(to: view)
    }

    /// Changing `contentInset` while the user is at the very top would leave
    /// the page scrolled into the inset, so nudge the offset to match when we
    /// were already pinned there.
    private func applyInsets(to view: ZenWebView) {
        let insets = UIEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)
        guard view.scrollView.contentInset != insets else { return }
        let wasAtTop = view.scrollView.contentOffset.y <= -view.scrollView.contentInset.top + 1
        view.scrollView.contentInset = insets
        // Keep the scroll indicators out from under the island too.
        view.scrollView.verticalScrollIndicatorInsets = insets
        view.syncUnderPageBackground()
        if wasAtTop {
            view.scrollView.setContentOffset(CGPoint(x: 0, y: -insets.top), animated: false)
        }
    }

    static func dismantleUIView(_ view: ZenWebView, coordinator: Coordinator) {
        // Do NOT tear the web view down here: SwiftUI dismantles the
        // representable whenever the tab leaves the view tree (switching tabs,
        // opening a sheet), and the pool — not SwiftUI — owns the lifetime.
        view.scrollView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate,
        UIScrollViewDelegate
    {
        let state: BrowserState
        let pool: WebViewPool
        var tabID: UUID?
        private var watchdog: Task<Void, Never>?

        init(state: BrowserState, pool: WebViewPool) {
            self.state = state
            self.pool = pool
        }

        func load(_ url: URL, in view: ZenWebView) {
            view.isProgrammaticNavigation = true
            view.lastRequestedURL = url
            if let tabID {
                // Deferred: this runs from updateUIView, and mutating observed
                // state inside a SwiftUI update is how you get a render loop.
                let id = tabID
                DispatchQueue.main.async { [weak state] in
                    state?.updateTab(id) { $0.loadFailure = nil }
                }
            }
            var request = URLRequest(url: url)
            // WebKit's own default is a minute. For a LAN address nothing is
            // listening on, that is a minute of staring at a blank page.
            request.timeoutInterval = LoadFailure.timeout
            view.load(request)
            startWatchdog(for: url, in: view)
        }

        /// WebKit does not always report a failure for an address that simply
        /// black-holes — it neither commits nor errors. The watchdog turns that
        /// silence into a visible timeout.
        private func startWatchdog(for url: URL, in view: ZenWebView) {
            watchdog?.cancel()
            let tabID = self.tabID
            watchdog = Task { [weak view, weak state] in
                try? await Task.sleep(for: .seconds(LoadFailure.timeout + 1))
                guard !Task.isCancelled, let view, let state else { return }
                // Committed or finished means WebKit got somewhere; leave it be.
                guard view.isLoading, let tabID else { return }
                view.stopLoading()
                state.updateTab(tabID) { $0.loadFailure = LoadFailure.timeoutFailure(url: url) }
            }
        }

        func cancelWatchdog() {
            watchdog?.cancel()
            watchdog = nil
        }

        /// Retry deliberately: clear the guard so the same URL is attempted
        /// again, which `reload()` would not do after a failed provisional
        /// load (there is nothing committed to reload).
        func retry(in view: ZenWebView) {
            guard let url = view.lastRequestedURL ?? tabID.flatMap({ state.tab(id: $0)?.url })
            else { return }
            view.lastRequestedURL = nil
            load(url, in: view)
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Something arrived, so the watchdog's job is done.
            cancelWatchdog()
            (webView as? ZenWebView)?.refreshPageBackgroundColor()
            guard let tabID else { return }
            state.updateTab(tabID) { $0.loadFailure = nil }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            cancelWatchdog()
            guard let tabID else { return }
            let zen = webView as? ZenWebView
            zen?.isProgrammaticNavigation = false
            zen?.refreshPageBackgroundColor()

            let title = webView.title ?? ""
            let url = webView.url
            state.updateTab(tabID) { tab in
                if !title.isEmpty { tab.title = title }
                if let url { tab.url = url }
            }
            if let url, !title.isEmpty || url.host != nil {
                state.history.record(url: url, title: title)
            }

            // Best-effort scroll restore, once, after the document settles.
            if let zen, zen.pendingScrollY > 0 {
                let offset = zen.pendingScrollY
                zen.pendingScrollY = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    zen.scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                }
            }
            // Barely there: an acknowledgement that the wait is over, not an
            // announcement. Suppressed outright while the page is scrolling.
            Haptics.shared.fire(.pageLoaded)
            fetchFavicon(webView)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            recordFailure(error, in: webView)
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            recordFailure(error, in: webView)
        }

        /// Turn a WebKit error into something the page can explain. Before
        /// this, a refused connection left a blank view and a lock glyph with
        /// nothing to tap — indistinguishable from a page that simply had not
        /// loaded yet.
        private func recordFailure(_ error: Error, in webView: WKWebView) {
            cancelWatchdog()
            guard let tabID, let tab = state.tab(id: tabID) else { return }
            let failedURL =
                (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
                ?? webView.url ?? tab.url
            guard let failure = LoadFailure.classify(error, url: failedURL) else { return }
            Haptics.shared.fire(.loadError)
            state.updateTab(tabID) { tab in
                tab.loadFailure = failure
                if tab.title.isEmpty { tab.title = URLDetector.prettyHost(failedURL) }
            }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // Hand schemes WebKit cannot render (tel:, mailto:, app links) to the
            // system rather than showing an error page.
            if let scheme = url.scheme?.lowercased(),
                !["http", "https", "about", "file", "data", "blob"].contains(scheme)
            {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
                return
            }
            decisionHandler(.allow)
        }

        /// `target="_blank"` and `window.open`. Zen routes cross-domain links
        /// from an app tab into a Glance; we do the same for pinned/essential
        /// tabs and open a real tab otherwise.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            let owner = tabID.flatMap { state.tab(id: $0) }
            let isAppTab = owner?.kind.resetsOnClose ?? false
            let differentHost = owner?.url.host != url.host
            if isAppTab && differentHost {
                state.openGlance(url: url)
            } else {
                state.newTab(url: url)
            }
            return nil
        }

        // MARK: Long-press link menu

        /// Add "Open in Glance" to WebKit's own link context menu.
        func webView(
            _ webView: WKWebView,
            contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
            completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
        ) {
            guard let url = elementInfo.linkURL else {
                completionHandler(nil)
                return
            }
            // This one we own: WebKit asks us for the menu before it plays any
            // system feedback, so the tap lands with the long-press.
            Haptics.shared.fire(.longPressMenu)
            let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
                [weak self] _ in
                guard let self else { return nil }
                return UIMenu(children: [
                    UIAction(
                        title: "Open in Glance",
                        image: UIImage(systemName: "rectangle.on.rectangle.angled")
                    ) { _ in
                        Haptics.shared.fire(.glanceOpen)
                        self.state.openGlance(url: url)
                    },
                    UIAction(
                        title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")
                    ) { _ in
                        Haptics.shared.fire(.tabOpen)
                        self.state.newTab(url: url)
                    },
                    UIAction(
                        title: "Open in Split", image: UIImage(systemName: "rectangle.split.2x1")
                    ) { _ in
                        if let tab = self.state.newTab(url: url, select: false) {
                            Haptics.shared.fire(.splitEnter)
                            self.state.split(with: tab.id)
                        }
                    },
                    UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                        UIPasteboard.general.url = url
                    },
                ])
            }
            completionHandler(config)
        }

        // MARK: Scroll offset, for session restore

        // Compact mode shows the bar *while* you are scrolling and hides it
        // again shortly after you stop, so the common case needs no gesture at
        // all. The grabber stays as the deliberate reveal.
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            NotificationCenter.default.post(name: .zenPageScrollBegan, object: nil)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Keeps the bar alive through a long flick: RootView restarts its
            // countdown on each of these, and they stop when the scroll does.
            guard scrollView.isDragging || scrollView.isDecelerating else { return }
            NotificationCenter.default.post(name: .zenPageScrollBegan, object: nil)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
            recordScroll(scrollView)
            if !willDecelerate {
                NotificationCenter.default.post(name: .zenPageScrollEnded, object: nil)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            recordScroll(scrollView)
            NotificationCenter.default.post(name: .zenPageScrollEnded, object: nil)
        }

        private func recordScroll(_ scrollView: UIScrollView) {
            guard let tabID else { return }
            let y = Double(scrollView.contentOffset.y)
            state.updateTab(tabID) { $0.scrollY = max(0, y) }
        }

        // MARK: Favicon

        private func fetchFavicon(_ webView: WKWebView) {
            guard let tabID, let pageURL = webView.url, let host = pageURL.host else { return }
            let js = """
                (function () {
                  var links = document.querySelectorAll(
                    "link[rel~='icon'], link[rel='shortcut icon'], link[rel='apple-touch-icon']");
                  var best = null, bestSize = -1;
                  for (var i = 0; i < links.length; i++) {
                    var s = links[i].getAttribute('sizes');
                    var n = s ? parseInt(s.split('x')[0], 10) || 0 : 0;
                    if (n > bestSize) { bestSize = n; best = links[i].href; }
                  }
                  return best;
                })()
                """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                let href = result as? String
                let fallback = URL(string: "https://\(host)/favicon.ico")
                guard let iconURL = href.flatMap(URL.init(string:)) ?? fallback else { return }
                Task { await self?.downloadFavicon(iconURL, for: tabID) }
            }
        }

        private func downloadFavicon(_ url: URL, for tabID: UUID) async {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                (response as? HTTPURLResponse)?.statusCode == 200,
                // Anything larger than this is not a favicon; do not bloat the
                // session file with it.
                data.count < 200_000,
                UIImage(data: data) != nil
            else { return }
            state.updateTab(tabID) { $0.faviconData = data }
        }
    }
}
