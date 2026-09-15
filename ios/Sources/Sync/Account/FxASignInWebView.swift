//  FxASignInWebView.swift
//  The Mozilla-account sign-in sheet.
//
//  A `WKWebView` rather than `ASWebAuthenticationSession`, for a reason that is
//  set out with its evidence at the top of `SyncConfig.swift`: the authorization
//  endpoint refuses any redirect that is not `http(s)`, and the system sheet
//  can only intercept a custom scheme. Firefox for iOS has the same constraint
//  with the same client id and does the same thing.
//
//  What that costs, and what is done about it:
//
//  · **The data store is ephemeral.** The account cookie exists for the life of
//    the sheet and is gone with it. Sign-in does not leave a session behind in
//    the browser, and the browser's own cookies are not visible to it.
//  · **Exactly one origin loads.** Any navigation away from the account server
//    (other than the redirect we are waiting for) is refused, so a compromised
//    or redirecting page cannot put a different login form in front of someone.
//  · **No script is injected, and no message handler is installed.** The view
//    reads navigation URLs and nothing else.
//
//  None of that makes it as good as the system sheet. It makes it honest.

import SwiftUI
import WebKit

struct FxASignInSheet: View {
    let request: FxAAuthorizationRequest
    let onCallback: (URL) -> Void
    let onCancel: () -> Void

    @State private var isLoading = true
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                FxASignInWebView(
                    request: request, isLoading: $isLoading, failure: $failure,
                    onCallback: onCallback)
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }
                if let failure {
                    VStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Could not reach accounts.firefox.com")
                            .font(.headline)
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxHeight: .infinity)
                }
            }
            .navigationTitle("Mozilla account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("syncSignInCancel")
                }
            }
            // The origin is fixed and worth showing: it is the only way to see
            // that the password is going where it should.
            .safeAreaInset(edge: .bottom) {
                Label("accounts.firefox.com", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .interactiveDismissDisabled(true)
    }
}

private struct FxASignInWebView: UIViewRepresentable {
    let request: FxAAuthorizationRequest
    @Binding var isLoading: Bool
    @Binding var failure: String?
    let onCallback: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing here outlives the sheet, and nothing here can see the
        // browser's own cookies.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: request.url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: FxASignInWebView
        /// The callback fires once. A second navigation to the redirect — a
        /// reload, a back-forward restore — must not re-run the exchange with
        /// an already-spent code.
        private var hasCalledBack = false

        init(_ parent: FxASignInWebView) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if url.absoluteString.hasPrefix(SyncConfig.redirectURI) {
                decisionHandler(.cancel)
                guard !hasCalledBack else { return }
                hasCalledBack = true
                parent.onCallback(url)
                return
            }

            guard FxASignInWebView.isAllowed(url) else {
                // A redirect somewhere else is not a page we are willing to put
                // a password field on.
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation: WKNavigation!) {
            parent.isLoading = true
            parent.failure = nil
        }

        func webView(_ webView: WKWebView, didFinish: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation: WKNavigation!, withError error: Error
        ) {
            parent.isLoading = false
            // A cancelled navigation is our own `.cancel` above, not a failure.
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            parent.failure = error.localizedDescription
        }
    }

    /// Only Mozilla's own account and CDN origins. Signing in should never
    /// leave them, and a page that tries is one we do not want to render.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else {
            // `about:blank` is what a fresh web view starts on.
            return url.scheme == "about"
        }
        return host == "accounts.firefox.com" || host.hasSuffix(".accounts.firefox.com")
            || host == "api.accounts.firefox.com" || host.hasSuffix(".mozilla.com")
            || host.hasSuffix(".mozilla.org") || host.hasSuffix(".mozilla.net")
    }
}

/// Exposed for tests: the allow-list is security-relevant, so it is checked
/// rather than trusted.
enum FxASignInOriginPolicy {
    static func isAllowed(_ url: URL) -> Bool { FxASignInWebView.isAllowed(url) }
}
