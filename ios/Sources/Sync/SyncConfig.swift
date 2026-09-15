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
//  ## The redirect, and why it is a `urn:`
//
//  Firefox for iOS registers `urn:ietf:wg:oauth:native:1` (RFC 8252's "private
//  URI" placeholder for a native app) and intercepts it inside its own
//  WKWebView. `ASWebAuthenticationSession` matches the callback by *scheme*,
//  so we hand it `urn`. If a future iOS stops matching non-hierarchical
//  schemes this is the one line to change, and `SyncSignInError` surfaces the
//  failure rather than hanging.

import Foundation

enum SyncConfig {

    /// Firefox for iOS's public OAuth client id — see the note above.
    static let oauthClientID = "1b1a3e44c54fbb58"

    /// Registered against that client id. Not ours to choose.
    static let redirectURI = "urn:ietf:wg:oauth:native:1"

    /// What `ASWebAuthenticationSession` matches the callback on.
    static let redirectScheme = "urn"

    /// `profile` for the display name and avatar, `oldsync` for the data. The
    /// scoped key we need is attached to the second.
    static let scopes = ["profile", SyncKeyBundle.oldSyncScope]

    static var scopeString: String { scopes.joined(separator: " ") }

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
