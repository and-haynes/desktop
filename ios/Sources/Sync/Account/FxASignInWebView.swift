//  FxASignInWebView.swift
//  The Mozilla-account sign-in sheet.
//
//  A `WKWebView` rather than `ASWebAuthenticationSession`, for a reason that is
//  set out with its evidence at the top of `SyncConfig.swift`: the authorization
//  endpoint refuses any redirect that is not `http(s)`, and the system sheet
//  can only intercept a custom scheme. Firefox for iOS has the same constraint
//  with the same client id and does the same thing.
//
//  It also speaks the same protocol, which is the fix for #008AA. This client
//  id is a **WebChannel** client: with `context=oauth_webchannel_v1` on the
//  authorization URL the content server never navigates to the redirect at
//  all — it posts the result as a DOM event and leaves the page where it is.
//  Before this, the sheet watched for a navigation that was never going to
//  come, which is precisely "submitted the form and nothing happened".
//  `FxAWebChannel.swift` documents the message protocol.
//
//  What the web view costs, and what is done about it:
//
//  · **The data store is ephemeral.** The account cookie exists for the life of
//    the sheet and is gone with it. Sign-in does not leave a session behind in
//    the browser, and the browser's own cookies are not visible to it.
//  · **Exactly one origin loads.** Any navigation away from the account server
//    (other than the redirect we are waiting for) is refused, so a compromised
//    or redirecting page cannot put a different login form in front of someone.
//  · **One script is injected, and it is the channel.** It listens for a single
//    named event, forwards only `detail`s addressed to `account_updates`, and
//    reads nothing else from the page. `state` is checked before any code is
//    spent, so a page that fakes an `oauth_login` gets nowhere.
//
//  None of that makes it as good as the system sheet. It makes it honest.

import SwiftUI
import WebKit

/// What the sheet can tell the service. An enum rather than four closures: the
/// sheet has one job, and the call sites read better as a switch.
enum FxASignInEvent: Sendable {
    /// `fxaccounts:oauth_login` — the sign-in, over the WebChannel.
    case login(FxAWebChannelOAuthLogin)
    /// A navigation to the registered redirect. Not expected with a WebChannel
    /// context, kept because it costs nothing and is the documented fallback
    /// if Mozilla ever re-scopes the client id.
    case redirect(URL)
    /// `fxaccounts:logout` / `fxaccounts:delete_account`.
    case signOutRequested
}

struct FxASignInSheet: View {
    let request: FxAAuthorizationRequest
    @ObservedObject var diagnostics: SyncDiagnostics
    let onEvent: (FxASignInEvent) -> Void
    let onCancel: () -> Void

    @State private var isLoading = true
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                FxASignInWebView(
                    request: request, diagnostics: diagnostics, isLoading: $isLoading,
                    failure: $failure, onEvent: onEvent)
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
    let diagnostics: SyncDiagnostics
    @Binding var isLoading: Bool
    @Binding var failure: String?
    let onEvent: (FxASignInEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing here outlives the sheet, and nothing here can see the
        // browser's own cookies.
        configuration.websiteDataStore = .nonPersistent()

        // The channel. Main frame only — FxA's page posts from the top
        // document, and an iframe that could reach this handler would be a way
        // to ask us for a status only the account server should be told.
        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(
                source: FxAWebChannel.userScript, injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        controller.add(context.coordinator, name: FxAWebChannel.handlerName)
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        diagnostics.succeeded(
            .authorizeOpened,
            "context=\(SyncConfig.webChannelContext), action=\(SyncConfig.webChannelAction)")
        webView.load(URLRequest(url: request.url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// The content controller retains its message handler. Without this the
    /// coordinator — and the closure graph behind it — outlives the sheet.
    ///
    /// **Order matters, and getting it wrong aborts the process.**
    /// `stopLoading()` calls `didFailProvisionalNavigation` back
    /// *synchronously*, and the coordinator's implementation writes to the
    /// sheet's `@Binding`s — which SwiftUI is in the middle of tearing down.
    /// Swift's exclusivity check catches the re-entrant write and traps. So the
    /// delegate goes first, and only then is the load stopped.
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: FxAWebChannel.handlerName)
        controller.removeAllUserScripts()
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let parent: FxASignInWebView
        weak var webView: WKWebView?
        /// The callback fires once. A second `oauth_login` — a reload, a
        /// back-forward restore — must not re-run the exchange with an
        /// already-spent code.
        private var hasCalledBack = false
        #if DEBUG
            private var hasProbed = false
        #endif

        init(_ parent: FxASignInWebView) {
            self.parent = parent
        }

        private var diagnostics: SyncDiagnostics { parent.diagnostics }

        // MARK: WebChannel

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            // The script posts a JSON string rather than a live object; see
            // `FxAWebChannel.userScript` for why.
            handleChannelMessage(message.body as? String)
        }

        private func handleChannelMessage(_ body: String?) {
            guard let body, let message = FxAWebChannelMessage(jsonString: body) else {
                diagnostics.log(.webChannel, "unparseable message", outcome: .failed)
                return
            }
            switch message.kind {
            case .loaded:
                diagnostics.succeeded(.pageLoaded, "fxaccounts:loaded")
            case .status:
                answerStatus(message)
            case .canLinkAccount:
                answerCanLinkAccount(message)
            case .oauthLogin:
                receiveLogin(message)
            case .logout, .deleteAccount:
                diagnostics.log(.signedOut, message.command)
                parent.onEvent(.signOutRequested)
            case .error:
                let detail =
                    message.data["error"]?.stringValue
                    ?? (try? message.data.serializedString()) ?? ""
                diagnostics.failed(.webChannel, message: "The sign-in page reported: \(detail)")
            case nil:
                // FxA adds commands; refusing to sign in because of one we have
                // not met would be a self-inflicted outage.
                diagnostics.log(.webChannel, "ignored \(message.command)")
            }
        }

        private func answerStatus(_ message: FxAWebChannelMessage) {
            diagnostics.log(.fxaStatus, "asked")
            send(reply: FxAWebChannel.statusData(), to: message) { [diagnostics] in
                diagnostics.succeeded(
                    .fxaStatus,
                    "answered: clientId \(SyncConfig.oauthClientID), engines "
                        + SyncConfig.webChannelEngines.joined(separator: ", "))
                #if DEBUG
                    self.runProbeIfRequested()
                #endif
            }
        }

        private func answerCanLinkAccount(_ message: FxAWebChannelMessage) {
            send(reply: FxAWebChannel.canLinkAccountData, to: message) { [diagnostics] in
                diagnostics.succeeded(.canLinkAccount, "answered ok: true")
            }
        }

        private func receiveLogin(_ message: FxAWebChannelMessage) {
            guard !hasCalledBack else {
                diagnostics.log(.oauthLogin, "duplicate ignored")
                return
            }
            guard let login = FxAWebChannelOAuthLogin(data: message.data) else {
                diagnostics.failed(
                    .oauthLogin,
                    message: "The sign-in page sent an oauth_login with no code or state.")
                return
            }
            hasCalledBack = true
            let declined =
                login.declinedSyncEngines.isEmpty
                ? "none declined"
                : "declined " + login.declinedSyncEngines.joined(separator: ", ")
            diagnostics.succeeded(
                .oauthLogin,
                "\(SyncDiagnostics.shape(login.code, label: "code")), \(declined)")
            parent.onEvent(.login(login))
        }

        /// Dispatch a `WebChannelMessageToContent`. A failure here is a dead
        /// flow — the page waits for an answer it will not get — so it is
        /// reported rather than dropped.
        private func send(
            reply data: JSONValue, to message: FxAWebChannelMessage,
            onSuccess: @escaping @MainActor () -> Void
        ) {
            guard let webView else { return }
            let script: String
            do {
                script = try FxAWebChannel.replyScript(
                    to: message.messageId, command: message.command, data: data)
            } catch {
                diagnostics.failed(.webChannel, error)
                return
            }
            webView.evaluateJavaScript(script) { [diagnostics] _, error in
                MainActor.assumeIsolated {
                    if let error {
                        diagnostics.failed(.webChannel, error)
                    } else {
                        onSuccess()
                    }
                }
            }
        }

        // MARK: Navigation

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
                diagnostics.log(.oauthLogin, "arrived by redirect, not WebChannel")
                parent.onEvent(.redirect(url))
                return
            }

            guard FxASignInWebView.isAllowed(url) else {
                // A redirect somewhere else is not a page we are willing to put
                // a password field on.
                decisionHandler(.cancel)
                diagnostics.log(
                    .webChannel, "blocked navigation to \(url.host ?? url.scheme ?? "?")")
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
            diagnostics.succeeded(
                .pageLoaded, webView.url.map { $0.host ?? $0.absoluteString } ?? "loaded")
            #if DEBUG
                // The FxA page is a single-page app: the document finishing is
                // not the app being alive. Give its script time to boot and ask
                // us for `fxa_status` — the probe fires on that answer, and
                // this is only the backstop for a page that never asks.
                scheduleProbeBackstop(webView)
            #endif
        }

        #if DEBUG
            /// The #008AA verification hook, compiled out of release builds.
            ///
            /// A real sign-in needs a real password, so the only way to prove
            /// that an `oauth_login` actually drives the exchange is to send
            /// one. With `-zenFxAWebChannelProbe <json>` on the command line
            /// the sheet dispatches that message into the page once, as if FxA
            /// had sent it. `__ZEN_STATE__` anywhere in the JSON is replaced
            /// with this request's real state, so the probe gets past the state
            /// check; the code is fake, so Mozilla answers the exchange with a
            /// 400 — and that failure arriving in the diagnostics transcript
            /// rather than vanishing is the thing being verified.
            private func scheduleProbeBackstop(_ webView: WKWebView) {
                guard Self.probeArgument != nil else { return }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(40))
                    self?.runProbeIfRequested()
                }
            }

            private func runProbeIfRequested() {
                guard !hasProbed, let webView, let json = Self.probeArgument else { return }
                hasProbed = true
                let filled = json.replacingOccurrences(
                    of: "__ZEN_STATE__", with: parent.request.state)
                diagnostics.log(
                    .webChannel,
                    "probe: dispatching into \(webView.url?.path ?? "?") "
                        + "(\(webView.title ?? "untitled"))")
                webView.evaluateJavaScript(
                    """
                    window.dispatchEvent(new CustomEvent("WebChannelMessageToChrome", {
                      detail: \(filled)
                    }));
                    """
                ) { [diagnostics] _, error in
                    MainActor.assumeIsolated {
                        if let error { diagnostics.failed(.webChannel, error) }
                    }
                }
            }

            private static var probeArgument: String? {
                let arguments = ProcessInfo.processInfo.arguments
                guard let index = arguments.firstIndex(of: "-zenFxAWebChannelProbe"),
                    arguments.index(after: index) < arguments.endIndex
                else { return nil }
                return arguments[arguments.index(after: index)]
            }
        #endif

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation: WKNavigation!, withError error: Error
        ) {
            parent.isLoading = false
            // A cancelled navigation is our own `.cancel` above, not a failure.
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            parent.failure = error.localizedDescription
            diagnostics.failed(.pageLoaded, error)
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
