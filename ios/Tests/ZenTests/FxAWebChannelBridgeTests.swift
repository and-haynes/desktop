//  FxAWebChannelBridgeTests.swift
//  The channel, in a real WKWebView.
//
//  `FxAWebChannelTests` checks the Swift side against recorded payloads. This
//  checks the part that only WebKit can answer: that the injected script really
//  does catch a `WebChannelMessageToChrome` dispatched by a page, that what
//  arrives at the message handler is what the page sent, and that our reply is
//  a `WebChannelMessageToContent` the page can read back.
//
//  No network: the page is a local HTML string, standing in for
//  accounts.firefox.com. What cannot be done here — and cannot be done at all
//  without a Mozilla account — is make the *real* content server send an
//  `fxaccounts:fxa_status`; it asks only once an email has been entered. See
//  the README.

import WebKit
import XCTest

@testable import Zen

@MainActor
final class FxAWebChannelBridgeTests: XCTestCase {

    private var webView: WKWebView!
    private var received: [String] = []
    private var onMessage: ((String) -> Void)?

    /// A page that speaks the browser half of the channel back at us: it
    /// records every `WebChannelMessageToContent` it is sent, so a reply can be
    /// read back out with `evaluateJavaScript`.
    private static let page = """
        <!doctype html><html><head><meta charset="utf-8"><title>stand-in</title></head>
        <body><script>
          window.__replies = [];
          window.addEventListener("WebChannelMessageToContent", function (e) {
            var d = e.detail;
            if (typeof d === "string") { d = JSON.parse(d); }
            window.__replies.push(d);
          });
          window.__send = function (detail) {
            window.dispatchEvent(new CustomEvent("WebChannelMessageToChrome", { detail: detail }));
          };
        </script></body></html>
        """

    override func setUp() async throws {
        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(
                source: FxAWebChannel.userScript, injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        controller.add(Handler(self), name: FxAWebChannel.handlerName)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        webView = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 480),
                            configuration: configuration)
        try await load(Self.page)
    }

    override func tearDown() async throws {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: FxAWebChannel.handlerName)
        webView = nil
        received = []
        onMessage = nil
    }

    private final class Handler: NSObject, WKScriptMessageHandler {
        private weak var owner: FxAWebChannelBridgeTests?
        init(_ owner: FxAWebChannelBridgeTests) { self.owner = owner }
        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? String else { return }
            MainActor.assumeIsolated {
                owner?.received.append(body)
                owner?.onMessage?(body)
            }
        }
    }

    // MARK: Plumbing

    private func load(_ html: String) async throws {
        webView.loadHTMLString(html, baseURL: URL(string: "https://accounts.firefox.com/oauth"))
        // `loadHTMLString` has no completion, and `document.readyState` answers
        // "complete" for the *previous* empty document straight away — which is
        // how the first version of this raced and failed on every test. Poll
        // for the page's own function instead: that only exists once its script
        // has run.
        for _ in 0..<400 {
            let kind =
                try? await webView.evaluateJavaScript("typeof window.__send") as? String
            if kind == "function" { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("the stand-in page never finished loading")
    }

    /// Dispatch from the page and wait for it to reach the handler.
    @discardableResult
    private func send(_ detail: String) async throws -> String {
        let expectation = expectation(description: "message crosses the bridge")
        var body = ""
        onMessage = { message in
            body = message
            expectation.fulfill()
        }
        _ = try await webView.evaluateJavaScript("window.__send(\(detail)); true")
        await fulfillment(of: [expectation], timeout: 5)
        onMessage = nil
        return body
    }

    private func replies() async throws -> [JSONValue] {
        let json =
            try await webView.evaluateJavaScript("JSON.stringify(window.__replies)") as? String
        return (try JSONValue(jsonString: json ?? "[]")).arrayValue ?? []
    }

    // MARK: The tests

    /// A page's event reaches the handler, intact.
    func testAMessageFromThePageReachesTheHandler() async throws {
        let body = try await send(FxAWebChannelMessageTests.statusRequest)
        let message = try XCTUnwrap(FxAWebChannelMessage(jsonString: body))
        XCTAssertEqual(message.kind, .status)
        XCTAssertEqual(message.messageId, "6ff4b1e9")
    }

    /// FxA's own sender stringifies its `detail`. Both forms have to work, or
    /// the channel breaks on a content-server deploy.
    func testAStringifiedDetailAlsoCrosses() async throws {
        let body = try await send("JSON.stringify(\(FxAWebChannelMessageTests.statusRequest))")
        XCTAssertEqual(FxAWebChannelMessage(jsonString: body)?.kind, .status)
    }

    /// Another channel's traffic is not ours to forward.
    func testAForeignChannelDoesNotCross() async throws {
        _ = try await webView.evaluateJavaScript(
            #"window.__send({"id":"not_us","message":{"command":"x","messageId":"1"}}); true"#)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(received.isEmpty)
    }

    /// The reply the sheet sends for `fxaccounts:fxa_status`, read back from
    /// the page that received it. This is the round trip the real flow depends
    /// on, minus Mozilla.
    func testTheStatusReplyArrivesAtThePage() async throws {
        let body = try await send(FxAWebChannelMessageTests.statusRequest)
        let message = try XCTUnwrap(FxAWebChannelMessage(jsonString: body))

        let script = try FxAWebChannel.replyScript(
            to: message.messageId, command: message.command, data: FxAWebChannel.statusData())
        _ = try await webView.evaluateJavaScript(script + " true")

        let replies = try await replies()
        XCTAssertEqual(replies.count, 1)
        let reply = try XCTUnwrap(replies.first)
        XCTAssertEqual(reply["id"]?.stringValue, "account_updates")
        XCTAssertEqual(reply["message"]?["messageId"]?.stringValue, "6ff4b1e9")
        XCTAssertEqual(reply["message"]?["command"]?.stringValue, "fxaccounts:fxa_status")
        let data = try XCTUnwrap(reply["message"]?["data"])
        XCTAssertEqual(data["signedInUser"], .null)
        XCTAssertEqual(data["clientId"]?.stringValue, SyncConfig.oauthClientID)
        XCTAssertEqual(data["capabilities"]?["choose_what_to_sync"]?.boolValue, true)
        XCTAssertEqual(
            data["capabilities"]?["engines"]?.arrayValue?.compactMap(\.stringValue),
            SyncConfig.webChannelEngines)
    }

    func testTheCanLinkAccountReplyArrivesAtThePage() async throws {
        let body = try await send(FxAWebChannelMessageTests.canLinkAccountRequest)
        let message = try XCTUnwrap(FxAWebChannelMessage(jsonString: body))
        _ = try await webView.evaluateJavaScript(
            try FxAWebChannel.replyScript(
                to: message.messageId, command: message.command,
                data: FxAWebChannel.canLinkAccountData) + " true")
        let all = try await replies()
        let reply = try XCTUnwrap(all.first)
        XCTAssertEqual(reply["message"]?["data"]?["ok"]?.boolValue, true)
    }

    /// The whole sign-in, as a message: this is what the simulator run drives
    /// against the live server, and what a real password would produce.
    func testAnOAuthLoginCrossesWithItsCodeAndState() async throws {
        let body = try await send(FxAWebChannelMessageTests.oauthLogin)
        let message = try XCTUnwrap(FxAWebChannelMessage(jsonString: body))
        let login = try XCTUnwrap(FxAWebChannelOAuthLogin(data: message.data))
        XCTAssertEqual(
            try FxAOAuthClient.authorizationCode(
                fromWebChannel: login, expectedState: "Zm9vYmFyLXN0YXRlLTAxMjM0NTY3"),
            "aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff0000000011111111")
    }

    /// Installed once per document, however many times the script is evaluated
    /// — a duplicate listener would send every message twice, and the second
    /// `oauth_login` would try to spend a code that is already gone.
    func testTheListenerIsInstalledOnlyOnce() async throws {
        _ = try await webView.evaluateJavaScript(FxAWebChannel.userScript + " true")
        let body = try await send(FxAWebChannelMessageTests.loadedRequest)
        XCTAssertEqual(FxAWebChannelMessage(jsonString: body)?.kind, .loaded)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(received.count, 1, "the message crossed more than once")
    }
}
