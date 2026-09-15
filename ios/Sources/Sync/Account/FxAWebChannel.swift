//  FxAWebChannel.swift
//  The protocol the Mozilla account page actually speaks (#008AA).
//
//  ## Why the redirect never fires
//
//  Firefox for iOS's OAuth client id — the one we sign in with, by Andy's
//  decision on #00893 — is registered as a **WebChannel** client. When the
//  authorization URL carries `context=oauth_webchannel_v1`, the content server
//  does not navigate anywhere at the end of the flow: it hands the result to
//  the embedding browser over a DOM event channel and leaves the page where it
//  is. Watching for a navigation to `/oauth/success/<client id>?code=…`, which
//  is what this app did before, therefore waits for something that will never
//  happen. That is #008AA: the form rendered, the password went in, and the
//  sheet sat there for ever.
//
//  ## The channel
//
//  Two `CustomEvent`s on `window`, both carrying a `detail` of the shape
//  `{ id, message: { command, data, messageId } }` with `id` always
//  `"account_updates"`:
//
//  · page → browser: **`WebChannelMessageToChrome`**. We listen for it in an
//    injected script and forward it to a `WKScriptMessageHandler`.
//  · browser → page: **`WebChannelMessageToContent`**, dispatched by us with
//    `evaluateJavaScript`. The reply echoes the `messageId` it answers, which
//    is how the page pairs request with response.
//
//  The commands, and what Firefox for iOS's `FxAWebViewModel.swift` answers —
//  this is a port of that behaviour, not an invention:
//
//  | Command | Answer |
//  |---|---|
//  | `fxaccounts:loaded` | none; the page is ready |
//  | `fxaccounts:fxa_status` | `{ signedInUser, clientId, capabilities }` |
//  | `fxaccounts:can_link_account` | `{ ok: true }` |
//  | `fxaccounts:oauth_login` | none; carries `code` and `state` — the sign-in |
//  | `fxaccounts:logout`, `fxaccounts:delete_account` | none; sign out |
//  | `fxaccounts:error` | none; surfaced in diagnostics |
//
//  `signedInUser` is `null` because this app never has an FxA session to offer
//  the page: the sheet's data store is ephemeral and thrown away with it.
//
//  ## The security cost, and what is done about it
//
//  The old sheet injected no script and installed no message handler, and said
//  so. It cannot stay that way and also work. The mitigations that remain:
//  the script is injected only into the sheet's web view (never the browser's),
//  only into the main frame, and only on the origins the allow-list already
//  permits; it reads nothing from the page — it forwards one named event and
//  ignores every `detail` whose `id` is not `account_updates`; and `state` on
//  the `oauth_login` message is checked against the one we generated before a
//  code is spent, so a page that manufactures a login cannot drive an exchange.

import Foundation

/// A parsed `WebChannelMessageToChrome`.
struct FxAWebChannelMessage: Equatable, Sendable {
    /// FxA's channel id. A `detail` addressed to anything else is not ours.
    static let channelID = "account_updates"

    let command: String
    /// Echoed back on the reply so the page can pair them. FxA omits it on
    /// messages it does not expect an answer to, so it is not required.
    let messageId: String
    let data: JSONValue

    /// Parse the `detail` of the event, which arrives from the injected script
    /// as a JSON string.
    init?(detail: JSONValue) {
        guard detail["id"]?.stringValue == Self.channelID,
            let message = detail["message"],
            let command = message["command"]?.stringValue, !command.isEmpty
        else { return nil }
        self.command = command
        self.messageId = message["messageId"]?.stringValue ?? ""
        self.data = message["data"] ?? .object([:])
    }

    init(command: String, messageId: String, data: JSONValue = .object([:])) {
        self.command = command
        self.messageId = messageId
        self.data = data
    }

    init?(jsonString: String) {
        guard let detail = try? JSONValue(jsonString: jsonString) else { return nil }
        self.init(detail: detail)
    }

    var kind: FxAWebChannelCommand? { FxAWebChannelCommand(rawValue: command) }
}

/// The commands this app knows how to answer. An unknown command is logged and
/// ignored — FxA adds them, and a browser that throws on one it has not met
/// breaks every time Mozilla ships.
enum FxAWebChannelCommand: String, Sendable, CaseIterable {
    case loaded = "fxaccounts:loaded"
    case status = "fxaccounts:fxa_status"
    case canLinkAccount = "fxaccounts:can_link_account"
    case oauthLogin = "fxaccounts:oauth_login"
    case logout = "fxaccounts:logout"
    case deleteAccount = "fxaccounts:delete_account"
    case error = "fxaccounts:error"
}

/// The payload of `fxaccounts:oauth_login`: the whole point of the flow.
struct FxAWebChannelOAuthLogin: Equatable, Sendable {
    let code: String
    let state: String
    /// Engines the user unticked on "choose what to sync". Honoured, because
    /// ignoring them would sync data someone explicitly declined.
    let declinedSyncEngines: [String]
    /// What the page offered — useful only for diagnostics.
    let offeredSyncEngines: [String]
    /// `signin` or `signup`. FxA sends it; we only log it.
    let action: String?

    init?(data: JSONValue) {
        guard let code = data["code"]?.stringValue, !code.isEmpty,
            let state = data["state"]?.stringValue, !state.isEmpty
        else { return nil }
        self.code = code
        self.state = state
        self.declinedSyncEngines = Self.strings(data["declinedSyncEngines"])
        self.offeredSyncEngines = Self.strings(data["offeredSyncEngines"])
        self.action = data["action"]?.stringValue
    }

    init(
        code: String, state: String, declinedSyncEngines: [String] = [],
        offeredSyncEngines: [String] = [], action: String? = nil
    ) {
        self.code = code
        self.state = state
        self.declinedSyncEngines = declinedSyncEngines
        self.offeredSyncEngines = offeredSyncEngines
        self.action = action
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

enum FxAWebChannel {

    /// The `WKScriptMessageHandler` name. Deliberately app-specific: a page
    /// that probes for `window.webkit.messageHandlers.fxa` should not find one.
    static let handlerName = "zenFxAWebChannel"

    // MARK: Page → browser

    /// Injected at document start into the sheet's main frame only.
    ///
    /// `detail` is stringified before it crosses, for one reason: a
    /// `WKScriptMessage.body` built from a live JS object arrives as a nest of
    /// `NSDictionary`/`NSNumber` whose types depend on the value, and the
    /// difference between `1` and `true` there is a source of exactly the
    /// bug this whole file is fixing. A JSON string decodes the same way every
    /// time.
    static let userScript = """
        (function () {
          if (window.__zenFxAWebChannelInstalled) { return; }
          window.__zenFxAWebChannelInstalled = true;
          var post = function (payload) {
            try {
              window.webkit.messageHandlers.\(handlerName).postMessage(payload);
            } catch (e) { /* the sheet went away mid-flight */ }
          };
          window.addEventListener("WebChannelMessageToChrome", function (event) {
            try {
              var detail = event.detail;
              if (typeof detail === "string") { detail = JSON.parse(detail); }
              if (!detail || detail.id !== "\(FxAWebChannelMessage.channelID)") { return; }
              post(JSON.stringify(detail));
            } catch (e) {
              post(JSON.stringify({
                id: "\(FxAWebChannelMessage.channelID)",
                message: {
                  command: "\(FxAWebChannelCommand.error.rawValue)",
                  messageId: "",
                  data: { error: String(e) }
                }
              }));
            }
          }, true);
        })();
        """

    // MARK: Browser → page

    /// The `detail` of a `WebChannelMessageToContent` answering `messageId`.
    static func reply(to messageId: String, command: String, data: JSONValue) -> JSONValue {
        .object([
            "id": .string(FxAWebChannelMessage.channelID),
            "message": .object([
                "command": .string(command),
                "messageId": .string(messageId),
                "data": data,
            ]),
        ])
    }

    /// The script that dispatches a reply.
    ///
    /// `detail` is an **object**, which is what desktop Firefox's WebChannel
    /// sends; FxA's receiver also accepts a JSON string (that is what Firefox
    /// for iOS sends), so either works — an object is chosen because it needs
    /// no parsing step on the page and cannot be misread as a plain string
    /// payload.
    static func dispatchScript(_ detail: JSONValue) throws -> String {
        let json = try detail.serializedString()
        return """
            (function () {
              window.dispatchEvent(new CustomEvent("WebChannelMessageToContent", {
                detail: \(json)
              }));
            })();
            """
    }

    /// Convenience: the whole reply, ready to evaluate.
    static func replyScript(to messageId: String, command: String, data: JSONValue) throws
        -> String
    {
        try dispatchScript(reply(to: messageId, command: command, data: data))
    }

    // MARK: The two answers that carry content

    /// `fxaccounts:fxa_status`.
    ///
    /// `signedInUser` is always `null`: the sheet's data store is ephemeral, so
    /// there is never a session here to tell the page about. `capabilities`
    /// drives the "choose what to sync" checkboxes, so it lists the engines
    /// this build actually syncs — offering `passwords` and then never syncing
    /// them would be a lie told in a checkbox.
    static func statusData(
        clientID: String = SyncConfig.oauthClientID,
        engines: [String] = SyncConfig.webChannelEngines
    ) -> JSONValue {
        .object([
            "signedInUser": .null,
            "clientId": .string(clientID),
            "capabilities": .object([
                "engines": .array(engines.map { JSONValue.string($0) }),
                "choose_what_to_sync": .bool(true),
            ]),
        ])
    }

    /// `fxaccounts:can_link_account`. Always yes: this app has no other
    /// account signed in that linking could clobber, which is the case the
    /// question exists for.
    static let canLinkAccountData = JSONValue.object(["ok": .bool(true)])
}
