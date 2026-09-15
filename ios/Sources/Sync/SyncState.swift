//  SyncState.swift
//  The non-secret half of sync: what the Settings screen shows, and the
//  persisted record of what the server holds.
//
//  Deliberately a separate file from the session snapshot. Sync state changes
//  on a different clock from tabs and spaces, and a corrupt sync file should
//  cost a full re-sync, not someone's open tabs.

import Foundation

/// Per-engine switches and the device's own name.
struct SyncPreferences: Codable, Equatable, Sendable {
    /// Master switch. Off means signed in but paused.
    var enabled: Bool = true
    /// Shown to every other device in the account. Empty means "use the
    /// system's name for this phone".
    var deviceName: String = ""
    var syncSpaces: Bool = true
    var syncBookmarks: Bool = true
    var syncTabs: Bool = true
    var syncHistory: Bool = true
    /// Zen desktop's `zen.spaces-sync.normal-tabs`, off there and off here:
    /// the spaces engine syncs pinned and essential tabs by default, because
    /// syncing every ordinary tab turns a browser into a filing cabinet.
    var syncNormalTabs: Bool = false

    init() {}

    /// Decode each key optionally, so a preferences file written before a
    /// switch existed still loads rather than resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SyncPreferences()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
            ?? fallback.deviceName
        syncSpaces = try c.decodeIfPresent(Bool.self, forKey: .syncSpaces) ?? fallback.syncSpaces
        syncBookmarks = try c.decodeIfPresent(Bool.self, forKey: .syncBookmarks)
            ?? fallback.syncBookmarks
        syncTabs = try c.decodeIfPresent(Bool.self, forKey: .syncTabs) ?? fallback.syncTabs
        syncHistory = try c.decodeIfPresent(Bool.self, forKey: .syncHistory)
            ?? fallback.syncHistory
        syncNormalTabs = try c.decodeIfPresent(Bool.self, forKey: .syncNormalTabs)
            ?? fallback.syncNormalTabs
    }

    func isEnabled(_ collection: String) -> Bool {
        guard enabled else { return false }
        switch collection {
        case SpacesEngine.collection: return syncSpaces
        case BookmarksEngine.collection: return syncBookmarks
        case TabsEngine.collection: return syncTabs
        case HistoryEngine.collection: return syncHistory
        // The clients record is not optional: without it this device is
        // invisible to every other one.
        default: return true
        }
    }

    /// `meta/global`'s `declined` list, so the desktop's Settings screen shows
    /// the same switches off that ours does.
    var declinedEngines: [String] {
        var declined: [String] = []
        if !syncSpaces { declined.append(SpacesEngine.collection) }
        if !syncBookmarks { declined.append(BookmarksEngine.collection) }
        if !syncTabs { declined.append(TabsEngine.collection) }
        if !syncHistory { declined.append(HistoryEngine.collection) }
        return declined
    }
}

/// Who is signed in. Never the tokens — those are in the keychain.
struct SyncAccountSummary: Codable, Equatable, Sendable {
    var email: String?
    var displayName: String?
    var signedInAt: Date?

    var label: String {
        displayName ?? email ?? "Mozilla account"
    }
}

/// The whole persisted sync document.
struct SyncStateFile: Codable, Equatable, Sendable {
    var shadow = SyncShadow()
    var preferences = SyncPreferences()
    var account: SyncAccountSummary?
    var lastSyncedAt: Date?
    var lastError: String?
    /// Cached so the sidebar can show other devices' tabs before the first
    /// sync of a launch finishes.
    var remoteTabs: [RemoteDeviceTabs] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shadow = try c.decodeIfPresent(SyncShadow.self, forKey: .shadow) ?? SyncShadow()
        preferences =
            try c.decodeIfPresent(SyncPreferences.self, forKey: .preferences)
            ?? SyncPreferences()
        account = try c.decodeIfPresent(SyncAccountSummary.self, forKey: .account)
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        remoteTabs =
            try c.decodeIfPresent([RemoteDeviceTabs].self, forKey: .remoteTabs) ?? []
    }
}

enum SyncStatus: Equatable, Sendable {
    case signedOut
    case idle
    case signingIn
    case syncing
    case paused
    case failed(String)
    /// The server asked for a pause; not a failure.
    case backingOff(until: Date)

    var isBusy: Bool { self == .syncing || self == .signingIn }

    var summary: String {
        switch self {
        case .signedOut: return "Not signed in"
        case .idle: return "Up to date"
        case .signingIn: return "Signing in…"
        case .syncing: return "Syncing…"
        case .paused: return "Paused"
        case .failed(let message): return message
        case .backingOff(let until):
            let seconds = max(0, Int(until.timeIntervalSinceNow))
            return "Server asked for a pause (\(seconds)s)"
        }
    }

    var symbol: String {
        switch self {
        case .signedOut: return "person.crop.circle.badge.questionmark"
        case .idle: return "checkmark.circle.fill"
        case .signingIn, .syncing: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .backingOff: return "clock.badge.exclamationmark.fill"
        }
    }
}
