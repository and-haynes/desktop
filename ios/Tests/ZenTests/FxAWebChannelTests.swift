//  FxAWebChannelTests.swift
//  The protocol that #008AA turned out to be: the sign-in result arrives as a
//  DOM event, not as a redirect.
//
//  The messages below are the shapes Firefox for iOS's `FxAWebViewModel`
//  handles and the FxA content server documents — `id: "account_updates"`,
//  a `message` carrying `command`, `messageId` and `data`. They are recorded
//  here as literal JSON rather than built with our own encoder on purpose: a
//  round trip through our own types would prove only that we agree with
//  ourselves, which is exactly the mistake that let the redirect assumption
//  survive this long.

import XCTest

@testable import Zen

final class FxAWebChannelMessageTests: XCTestCase {

    // MARK: Recorded messages

    /// What the page asks first: "who is signed in, and what can you sync?"
    static let statusRequest = """
        {"id":"account_updates","message":{"command":"fxaccounts:fxa_status",\
        "messageId":"6ff4b1e9","data":{"service":"sync","context":"oauth_webchannel_v1"}}}
        """

    static let canLinkAccountRequest = """
        {"id":"account_updates","message":{"command":"fxaccounts:can_link_account",\
        "messageId":"2","data":{"email":"someone@example.com"}}}
        """

    static let loadedRequest = """
        {"id":"account_updates","message":{"command":"fxaccounts:loaded","messageId":"1"}}
        """

    /// The one that matters. `code` and `state` here are the shapes FxA
    /// sends — 64 hex characters each — with values that are obviously fake.
    static let oauthLogin = """
        {"id":"account_updates","message":{"command":"fxaccounts:oauth_login","messageId":"4",\
        "data":{"action":"signin",\
        "code":"aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff0000000011111111",\
        "state":"Zm9vYmFyLXN0YXRlLTAxMjM0NTY3",\
        "declinedSyncEngines":["history"],\
        "offeredSyncEngines":["bookmarks","history","tabs"]}}}
        """

    static let logout = """
        {"id":"account_updates","message":{"command":"fxaccounts:logout","messageId":"9",\
        "data":{"uid":"0123456789abcdef"}}}
        """

    // MARK: Parsing

    func testParsesAStatusRequest() throws {
        let message = try XCTUnwrap(FxAWebChannelMessage(jsonString: Self.statusRequest))
        XCTAssertEqual(message.kind, .status)
        XCTAssertEqual(message.messageId, "6ff4b1e9")
        XCTAssertEqual(message.data["service"]?.stringValue, "sync")
    }

    func testParsesACanLinkAccountRequest() throws {
        let message = try XCTUnwrap(FxAWebChannelMessage(jsonString: Self.canLinkAccountRequest))
        XCTAssertEqual(message.kind, .canLinkAccount)
        XCTAssertEqual(message.messageId, "2")
    }

    /// `fxaccounts:loaded` carries no `data`. Requiring one would drop the
    /// "the page is ready" signal, which is the first line of the transcript.
    func testParsesALoadedNotificationWithNoData() throws {
        let message = try XCTUnwrap(FxAWebChannelMessage(jsonString: Self.loadedRequest))
        XCTAssertEqual(message.kind, .loaded)
        XCTAssertEqual(message.data, .object([:]))
    }

    func testParsesLogout() throws {
        let message = try XCTUnwrap(FxAWebChannelMessage(jsonString: Self.logout))
        XCTAssertEqual(message.kind, .logout)
    }

    /// A command we have never met is still a well-formed message. Mozilla
    /// adds them; refusing to parse one would break sign-in on their schedule.
    func testAnUnknownCommandParsesWithNoKind() throws {
        let json = """
            {"id":"account_updates","message":{"command":"fxaccounts:something_new",\
            "messageId":"7","data":{}}}
            """
        let message = try XCTUnwrap(FxAWebChannelMessage(jsonString: json))
        XCTAssertNil(message.kind)
        XCTAssertEqual(message.command, "fxaccounts:something_new")
    }

    /// Anything not addressed to `account_updates` is some other page's
    /// business — a site could dispatch the event name at us.
    func testRejectsAnotherChannelsMessage() {
        let json = """
            {"id":"some_other_channel","message":{"command":"fxaccounts:fxa_status",\
            "messageId":"1","data":{}}}
            """
        XCTAssertNil(FxAWebChannelMessage(jsonString: json))
    }

    func testRejectsMalformedMessages() {
        XCTAssertNil(FxAWebChannelMessage(jsonString: "not json"))
        XCTAssertNil(FxAWebChannelMessage(jsonString: #"{"id":"account_updates"}"#))
        XCTAssertNil(
            FxAWebChannelMessage(
                jsonString: #"{"id":"account_updates","message":{"messageId":"1"}}"#))
        XCTAssertNil(
            FxAWebChannelMessage(
                jsonString: #"{"id":"account_updates","message":{"command":"","messageId":"1"}}"#))
    }

    // MARK: oauth_login

    func testParsesAnOAuthLogin() throws {
        let message = try XCTUnwrap(FxAWebChannelMessage(jsonString: Self.oauthLogin))
        let login = try XCTUnwrap(FxAWebChannelOAuthLogin(data: message.data))
        XCTAssertEqual(login.code.count, 64)
        XCTAssertEqual(login.state, "Zm9vYmFyLXN0YXRlLTAxMjM0NTY3")
        XCTAssertEqual(login.declinedSyncEngines, ["history"])
        XCTAssertEqual(login.offeredSyncEngines, ["bookmarks", "history", "tabs"])
        XCTAssertEqual(login.action, "signin")
    }

    func testAnOAuthLoginWithoutACodeOrStateIsNotOne() {
        XCTAssertNil(FxAWebChannelOAuthLogin(data: .object(["state": .string("s")])))
        XCTAssertNil(FxAWebChannelOAuthLogin(data: .object(["code": .string("c")])))
        XCTAssertNil(
            FxAWebChannelOAuthLogin(
                data: .object(["code": .string(""), "state": .string("s")])))
    }

    /// The engine lists are optional; an account with nothing to choose sends
    /// neither, and that must not look like a malformed login.
    func testMissingEngineListsBecomeEmpty() throws {
        let login = try XCTUnwrap(
            FxAWebChannelOAuthLogin(
                data: .object(["code": .string("c"), "state": .string("s")])))
        XCTAssertEqual(login.declinedSyncEngines, [])
        XCTAssertEqual(login.offeredSyncEngines, [])
        XCTAssertNil(login.action)
    }

    // MARK: State validation

    func testStateMustMatchTheRequestWeMade() throws {
        let login = FxAWebChannelOAuthLogin(code: "the-code", state: "the-state")
        XCTAssertEqual(
            try FxAOAuthClient.authorizationCode(
                fromWebChannel: login, expectedState: "the-state"),
            "the-code")
    }

    /// A page that manufactures an `oauth_login` cannot know the state we
    /// generated, so this is the check that stops one driving an exchange.
    func testAMismatchedStateIsRefused() {
        let login = FxAWebChannelOAuthLogin(code: "the-code", state: "somebody-elses-state")
        XCTAssertThrowsError(
            try FxAOAuthClient.authorizationCode(fromWebChannel: login, expectedState: "ours")
        ) { error in
            XCTAssertEqual(
                error as? SyncError,
                .message("Sign-in response did not match this request."))
        }
    }

    // MARK: Replies

    func testTheStatusReplyIsWhatFirefoxForIOSAnswers() throws {
        let data = FxAWebChannel.statusData()
        XCTAssertEqual(data["signedInUser"], .null)
        XCTAssertEqual(data["clientId"]?.stringValue, SyncConfig.oauthClientID)
        XCTAssertEqual(data["capabilities"]?["choose_what_to_sync"]?.boolValue, true)
        XCTAssertEqual(
            data["capabilities"]?["engines"]?.arrayValue?.compactMap(\.stringValue),
            SyncConfig.webChannelEngines)
    }

    /// `spaces` is Zen's own collection. Offering it as a "choose what to
    /// sync" checkbox would ask FxA to draw a control for an engine it has
    /// never heard of.
    func testTheAdvertisedEnginesAreOnesFirefoxSyncKnows() {
        XCTAssertFalse(SyncConfig.webChannelEngines.contains(SpacesEngine.collection))
        for engine in SyncConfig.webChannelEngines {
            XCTAssertTrue(
                ["bookmarks", "history", "tabs", "passwords", "addresses", "creditcards"]
                    .contains(engine), "unexpected engine \(engine)")
        }
    }

    func testCanLinkAccountIsAnsweredYes() {
        XCTAssertEqual(FxAWebChannel.canLinkAccountData["ok"]?.boolValue, true)
    }

    /// The reply envelope echoes the `messageId` it answers — that is how the
    /// page pairs an answer with its question, and a reply without it is
    /// ignored by the content server.
    func testTheReplyEnvelopeEchoesTheMessageId() throws {
        let message = try XCTUnwrap(FxAWebChannelMessage(jsonString: Self.statusRequest))
        let reply = FxAWebChannel.reply(
            to: message.messageId, command: message.command, data: FxAWebChannel.statusData())
        XCTAssertEqual(reply["id"]?.stringValue, "account_updates")
        XCTAssertEqual(reply["message"]?["messageId"]?.stringValue, "6ff4b1e9")
        XCTAssertEqual(reply["message"]?["command"]?.stringValue, "fxaccounts:fxa_status")
        XCTAssertEqual(reply["message"]?["data"]?["clientId"]?.stringValue, SyncConfig.oauthClientID)
    }

    func testTheReplyScriptDispatchesTheRightEvent() throws {
        let script = try FxAWebChannel.replyScript(
            to: "abc", command: FxAWebChannelCommand.canLinkAccount.rawValue,
            data: FxAWebChannel.canLinkAccountData)
        XCTAssertTrue(script.contains("WebChannelMessageToContent"))
        XCTAssertTrue(script.contains("window.dispatchEvent"))
        // The detail is a JS object literal, as desktop Firefox sends.
        XCTAssertTrue(script.contains(#""messageId":"abc""#))
        XCTAssertTrue(script.contains(#""ok":true"#))
        XCTAssertFalse(script.contains("WebChannelMessageToChrome"))
    }

    /// A reply is embedded in a script, so a `"` or `</script>` in a value
    /// must not be able to end the string it sits in. `JSONEncoder` escapes,
    /// and this is the test that says so.
    func testAReplyCannotBreakOutOfItsScript() throws {
        let script = try FxAWebChannel.dispatchScript(
            .object(["id": .string("account_updates\" ; alert(1); \"")]))
        XCTAssertFalse(script.contains("; alert(1); \""))
        XCTAssertTrue(script.contains(#"\" ; alert(1); \""#))
    }

    // MARK: The injected script

    func testTheInjectedScriptListensAndForwards() {
        let script = FxAWebChannel.userScript
        XCTAssertTrue(script.contains("WebChannelMessageToChrome"))
        XCTAssertTrue(
            script.contains("window.webkit.messageHandlers.\(FxAWebChannel.handlerName)"))
        // Only our channel crosses the bridge.
        XCTAssertTrue(script.contains(#"detail.id !== "account_updates""#))
        // Installed once, however many navigations the flow makes.
        XCTAssertTrue(script.contains("__zenFxAWebChannelInstalled"))
    }

    // MARK: The authorization URL

    /// The root cause of #008AA: without `context`, this client id finishes the
    /// flow by a redirect it never actually performs.
    func testTheAuthorizationURLAsksForAWebChannelFlow() throws {
        let request = try FxAOAuthClient().authorizationRequest()
        let items = try XCTUnwrap(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(query["context"], "oauth_webchannel_v1")
        XCTAssertEqual(query["action"], "email")
        // The rest of the request is unchanged — these were verified against
        // Mozilla's live server on #00892 and must not regress.
        XCTAssertEqual(query["client_id"], SyncConfig.oauthClientID)
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertNotNil(query["keys_jwk"])
        XCTAssertEqual(query["redirect_uri"], SyncConfig.redirectURI)
    }
}
