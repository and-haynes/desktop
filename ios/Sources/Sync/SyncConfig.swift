//  SyncConfig.swift
//  Every constant that decides *which* Firefox Sync we talk to, in one file.
//
//  ## The OAuth client id (#00893)
//
//  Mozilla does not hand out client ids to third-party browsers, and the
//  `https://identity.mozilla.com/apps/oldsync` scope is only granted to clients
//  Mozilla has allow-listed. Andy's decision on #00893 was to use Firefox for
//  iOS's own public client id and behave as an unofficial client, rather than
//  ship a sync feature that cannot reach the data. The consequences are worth
//  being honest about:
//
//  · The consent screen will say *Firefox*, not Zen. There is nothing we can
//    do about that short of Mozilla issuing us an id.
//  · Mozilla can revoke or re-scope the id at any time, and the feature stops
//    working the day they do.
//  · The redirect URI must be one that id already has registered — we cannot
//    add ours — which is why `redirectURI` below is not a Zen scheme.
//
//  ## The redirect, and why sign-in is a web view rather than
//  `ASWebAuthenticationSession`
//
//  `ASWebAuthenticationSession` matches a callback by **scheme**, so it needs a
//  redirect like `zen://fxa`. Mozilla's authorization endpoint will not accept
//  one. Verified on 2026-09-15 by loading the authorization URL in the
//  simulator's Safari (`ios/docs/screenshots/29b-sync-signin-page.png`):
//
//      redirect_uri=urn:ietf:wg:oauth:native:1  → Bad Request: Invalid Query Parameters
//      redirect_uri=zen://fxa-callback          → Bad Request: Invalid Query Parameters
//      redirect_uri=https://accounts.firefox.com/oauth/success/<client id>
//                                               → the sign-in form
//      (redirect_uri omitted)                   → the sign-in form
//
//  Everything else in the request — this client id, the `oldsync` scope, the
//  PKCE challenge, `access_type=offline` and `keys_jwk` — is accepted; only the
//  scheme is the problem. So the redirect has to be an `https:` URL, and an
//  `https:` URL is exactly what `ASWebAuthenticationSession` cannot intercept.
//
//  Firefox for iOS has the same constraint with the same client id and solves
//  it the same way: it runs the flow in its own `WKWebView` and watches for a
//  navigation to `/oauth/success/<client id>?code=…`. We do that too, in an
//  **ephemeral** data store so no account cookie outlives the sheet.
//
//  The trade-off is real and belongs on the record: the password is typed into
//  a web view this process owns rather than into Safari's. Zen never touches
//  the field — the view loads exactly one origin and is thrown away — but "we
//  promise not to look" is weaker than "we cannot look", which is what the
//  system sheet gives. The way to get that back is a client id of our own with
//  a Zen scheme registered; `usesSystemAuthSession` below is the one line to
//  flip if Mozilla ever issues one.

import Foundation

enum SyncConfig {

    /// Firefox for iOS's public OAuth client id — see the note above.
    static let oauthClientID = "1b1a3e44c54fbb58"

    /// Registered against that client id, and not ours to choose. FxA's own
    /// "success" page: the code arrives as a query on a navigation to it.
    static let redirectURI = "https://accounts.firefox.com/oauth/success/\(oauthClientID)"

    /// Whether to use the system sign-in sheet. `false` because the redirect
    /// above is `https:` and `ASWebAuthenticationSession` matches by scheme —
    /// see the note at the top of this file. With a client id of our own and a
    /// Zen scheme registered, this and `redirectURI` are the only two lines
    /// that change.
    static let usesSystemAuthSession = false

    /// Only meaningful when `usesSystemAuthSession` is true.
    static let redirectScheme = "zen"

    /// `profile` for the display name and avatar, `oldsync` for the data. The
    /// scoped key we need is attached to the second.
    static let scopes = ["profile", SyncKeyBundle.oldSyncScope]

    static var scopeString: String { scopes.joined(separator: " ") }

    // MARK: WebChannel (#008AA)
    //
    // This client id is a WebChannel client: with `context` set below, the
    // content server delivers the authorization code over a DOM event channel
    // instead of navigating to `redirectURI`, and a browser waiting for that
    // navigation waits for ever. `FxAWebChannel.swift` has the protocol.

    /// The `context` that turns the flow into a WebChannel one. Firefox for
    /// iOS sends exactly this.
    static let webChannelContext = "oauth_webchannel_v1"

    /// Firefox for iOS sends `action=email` so the flow starts on the
    /// email-first form rather than assuming a session the sheet cannot have.
    static let webChannelAction = "email"

    /// Advertised to the page in `fxaccounts:fxa_status` — it is what the
    /// "choose what to sync" checkboxes are drawn from. Only engines this
    /// build genuinely syncs, and only names Firefox Sync knows: `spaces` is
    /// Zen's own collection and is not something FxA can offer a checkbox for.
    static let webChannelEngines = ["bookmarks", "history", "tabs"]

    // MARK: Endpoints

    /// Discovery document. Everything below is a fallback for when it cannot
    /// be fetched — the live values win, because Mozilla moves hosts.
    static let clientConfigurationURL = URL(
        string: "https://accounts.firefox.com/.well-known/fxa-client-configuration")!

    static let defaultContentServer = URL(string: "https://accounts.firefox.com")!
    static let defaultOAuthServer = URL(string: "https://oauth.accounts.firefox.com/v1")!
    static let defaultProfileServer = URL(string: "https://profile.accounts.firefox.com/v1")!
    static let defaultTokenServer = URL(string: "https://token.services.mozilla.com")!

    /// The token server path that speaks Sync 1.5.
    static let tokenServerPath = "/1.0/sync/1.5"

    // MARK: Storage protocol

    /// `meta/global`'s `storageVersion`. Anything else and we must not touch
    /// the account's data.
    static let storageVersion = 5

    /// Advertised in the `clients` record.
    static let syncProtocolVersion = "1.5"

    // MARK: Engine versions
    //
    // Each must match what desktop writes into `meta/global`, or the desktop
    // wipes the collection and starts again. `spaces` is Zen's own engine —
    // `ZenSpacesSyncEngine.version` is 3.

    static let engineVersions: [String: Int] = [
        "spaces": 3,
        "bookmarks": 2,
        "history": 1,
        "tabs": 1,
        "clients": 1,
    ]

    // MARK: Cadence

    /// How often a foreground app syncs on its own.
    static let periodicInterval: TimeInterval = 15 * 60

    /// Don't sync on every foreground — coming back from a two-second
    /// glance at a notification is not a reason to hit the network.
    static let foregroundMinimumInterval: TimeInterval = 2 * 60

    /// Sync's own limit for a single POST body, and the one we batch against.
    static let maxPostRecords = 100
    static let maxPostBytes = 1_000_000
}
