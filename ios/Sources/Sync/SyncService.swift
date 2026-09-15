//  SyncService.swift
//  One sync, start to finish.
//
//  The order below is not arbitrary: `meta/global` decides whether our idea of
//  the account is still valid, `crypto/keys` is what everything else is read
//  with, and the spaces engine runs before the rest so that a tab arriving in
//  the tabs collection has a space to be shown against.
//
//      info/collections → meta/global → crypto/keys
//        → spaces → bookmarks → tabs → history → clients
//
//  Everything that touches the browser model happens on the main actor;
//  everything that touches the network happens off it, behind the storage
//  client's actor. The engines themselves are pure functions over value types,
//  which is what makes the merge testable without either.

import Combine
import Foundation
import SwiftUI

@MainActor
final class SyncService: ObservableObject {

    // MARK: Published state

    @Published private(set) var status: SyncStatus = .signedOut
    @Published private(set) var account: SyncAccountSummary?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var remoteTabs: [RemoteDeviceTabs] = []
    @Published var preferences: SyncPreferences {
        didSet {
            guard preferences != oldValue else { return }
            persist()
            if !preferences.enabled, status == .idle { status = .paused }
            if preferences.enabled, status == .paused { status = .idle }
        }
    }

    var isSignedIn: Bool { account != nil }

    /// The name other devices see. Empty preference means "ask the system".
    var effectiveDeviceName: String {
        preferences.deviceName.isEmpty
            ? ClientsEngine.defaultDeviceName() : preferences.deviceName
    }

    // MARK: Collaborators

    private let file: JSONFileStore<SyncStateFile>
    private let secrets: SyncSecretStoring
    private let transport: HTTPTransport
    private var endpoints: FxAEndpoints
    private weak var browser: BrowserState?

    private var state: SyncStateFile
    private var signInFlow: FxASignInFlow?
    private var syncTask: Task<Void, Never>?
    private var timer: Timer?
    private var lastAttemptAt: Date?

    /// Injected so tests can drive the clock and the network.
    private let now: @Sendable () -> Date

    init(
        file: JSONFileStore<SyncStateFile>? = nil,
        secrets: SyncSecretStoring = KeychainSecretStore(),
        transport: HTTPTransport = URLSessionTransport(),
        endpoints: FxAEndpoints = .fallback,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.file = file ?? JSONFileStore<SyncStateFile>(name: "sync-state.json")
        self.secrets = secrets
        self.transport = transport
        self.endpoints = endpoints
        self.now = now

        let loaded = self.file.load() ?? SyncStateFile()
        state = loaded
        preferences = loaded.preferences
        account = loaded.account
        lastSyncedAt = loaded.lastSyncedAt
        remoteTabs = loaded.remoteTabs
        status =
            loaded.account == nil
            ? .signedOut : (loaded.preferences.enabled ? .idle : .paused)
    }

    func attach(to browser: BrowserState) {
        self.browser = browser
    }

    // MARK: Sign in / out

    func signIn() async {
        guard !status.isBusy else { return }
        status = .signingIn
        let flow = FxASignInFlow()
        signInFlow = flow
        do {
            // Discovery first: Mozilla moves hosts, and a stale constant is a
            // sign-in that fails for no visible reason.
            endpoints = await FxAOAuthClient.discoverEndpoints(transport: transport)
            let client = FxAOAuthClient(endpoints: endpoints, transport: transport)
            let tokens = try await flow.signIn(client: client)
            guard let scopedKey = tokens.scopedKey else {
                throw SyncError.scopedKeyMissing
            }

            var secrets = SyncSecrets()
            secrets.refreshToken = tokens.refreshToken
            secrets.accessToken = tokens.accessToken
            secrets.accessTokenExpiresAt = tokens.expiresAt
            secrets.scopedKey = scopedKey
            self.secrets.save(secrets)

            let profile = try? await client.profile(accessToken: tokens.accessToken)
            account = SyncAccountSummary(
                email: profile?.email, displayName: profile?.displayName, signedInAt: now())
            state.account = account
            state.lastError = nil
            persist()
            status = preferences.enabled ? .idle : .paused
            signInFlow = nil
            syncNow(reason: .signIn)
        } catch let error as SyncError {
            signInFlow = nil
            status = error == .cancelled ? .signedOut : .failed(error.localizedDescription)
        } catch {
            signInFlow = nil
            status = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        syncTask?.cancel()
        syncTask = nil
        stopTimer()

        if let refreshToken = secrets.load()?.refreshToken {
            await FxAOAuthClient(endpoints: endpoints, transport: transport)
                .revoke(refreshToken: refreshToken)
        }
        secrets.clear()

        // Keep nothing about the account, including the shadow: signing back
        // in should be a clean first sync, not a merge against someone else's
        // idea of what the server holds.
        state = SyncStateFile()
        state.preferences = preferences
        account = nil
        lastSyncedAt = nil
        remoteTabs = []
        status = .signedOut
        persist()
    }

    // MARK: Scheduling

    enum SyncReason: Equatable {
        case manual
        case signIn
        case foreground
        case periodic
        /// The browser changed and we want the change not to be lost.
        case localChange
    }

    func start() {
        guard isSignedIn else { return }
        startTimer()
        syncNow(reason: .foreground)
    }

    func applicationDidEnterBackground() {
        stopTimer()
        persist()
    }

    func syncNow(reason: SyncReason = .manual) {
        guard isSignedIn, preferences.enabled else { return }
        guard syncTask == nil else { return }

        // Coming back from a two-second glance at a notification is not a
        // reason to hit the network.
        if reason == .foreground || reason == .periodic,
            let last = lastAttemptAt,
            now().timeIntervalSince(last) < SyncConfig.foregroundMinimumInterval
        {
            return
        }
        if case .backingOff(let until) = status, until > now(), reason != .manual { return }

        lastAttemptAt = now()
        status = .syncing
        syncTask = Task { [weak self] in
            await self?.runSync()
            self?.syncTask = nil
        }
    }

    /// The browser changed. Stamp the journal now — that timestamp is what the
    /// merge uses later, and "now" is the honest answer even offline.
    func noteLocalChange() {
        guard isSignedIn, preferences.syncSpaces, let browser else { return }
        var shadow = state.shadow[SpacesEngine.collection]
        SpacesEngine.journalLocalChanges(
            state: browser.spacesState, shadow: &shadow,
            identities: &state.shadow.identities,
            symbolShadow: &state.shadow.spaceSymbolShadow,
            syncNormalTabs: preferences.syncNormalTabs,
            now: now().timeIntervalSince1970)
        state.shadow[SpacesEngine.collection] = shadow
        persist()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(
            withTimeInterval: SyncConfig.periodicInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.syncNow(reason: .periodic) }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: The sync itself

    private func runSync() async {
        do {
            try await performSync()
            state.lastError = nil
            lastSyncedAt = now()
            state.lastSyncedAt = lastSyncedAt
            status = preferences.enabled ? .idle : .paused
        } catch let error as SyncError {
            switch error {
            case .backoff(let seconds):
                status = .backingOff(until: now().addingTimeInterval(seconds))
            case .authenticationExpired:
                // The refresh token is gone or revoked. Keep the account row
                // so the owner can see *why* they are being asked again.
                status = .failed(error.localizedDescription)
                state.lastError = error.localizedDescription
            default:
                status = .failed(error.localizedDescription)
                state.lastError = error.localizedDescription
            }
        } catch is CancellationError {
            status = preferences.enabled ? .idle : .paused
        } catch {
            status = .failed(error.localizedDescription)
            state.lastError = error.localizedDescription
        }
        persist()
    }

    private func performSync() async throws {
        guard var secrets = secrets.load() else { throw SyncError.notSignedIn }
        guard let scopedKey = secrets.scopedKey, let syncKey = scopedKey.keyBundle else {
            throw SyncError.scopedKeyMissing
        }

        // 1. A live access token.
        let client = FxAOAuthClient(endpoints: endpoints, transport: transport)
        if secrets.accessToken == nil
            || (secrets.accessTokenExpiresAt.map { now().addingTimeInterval(60) >= $0 } ?? true)
        {
            guard let refreshToken = secrets.refreshToken else {
                throw SyncError.authenticationExpired
            }
            let refreshed = try await client.refresh(refreshToken: refreshToken)
            secrets.accessToken = refreshed.accessToken
            secrets.accessTokenExpiresAt = refreshed.expiresAt
            secrets.refreshToken = refreshed.refreshToken ?? refreshToken
            self.secrets.save(secrets)
        }
        guard let accessToken = secrets.accessToken else {
            throw SyncError.authenticationExpired
        }

        // 2. A storage node and Hawk credentials.
        let tokenClient = TokenServerClient(
            baseURL: endpoints.tokenServer, transport: transport)
        var token = secrets.token
        if token == nil || token!.isExpired() {
            token = try await tokenClient.token(
                accessToken: accessToken, keyID: scopedKey.kid)
            secrets.token = token
            self.secrets.save(secrets)
        }
        guard let token else { throw SyncError.authenticationExpired }

        let storage = SyncStorageClient(
            token: token, transport: transport,
            renewToken: { try await tokenClient.token(accessToken: accessToken, keyID: scopedKey.kid) }
        )

        // 3. What has changed at all?
        let info = try await storage.infoCollections()

        // 4. meta/global — the account's storage format and per-engine syncIDs.
        try await reconcileMetaGlobal(storage: storage, info: info)

        // 5. crypto/keys.
        let keys: CollectionKeys
        if let existing = try await storage.cryptoKeys(syncKey: syncKey) {
            keys = existing
        } else {
            // A brand-new account. Write keys before anything is encrypted
            // with them, or the next client cannot read a thing.
            let fresh = CollectionKeys.generate()
            let payload = try BSOCrypto.encryptJSON(fresh.json, with: syncKey)
            _ = try await storage.put(
                collection: "crypto", id: "keys",
                payload: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self),
                unmodifiedSince: nil)
            keys = fresh
        }
        secrets.collectionKeys = keys
        self.secrets.save(secrets)

        // 6. Engines, in order.
        if preferences.isEnabled(SpacesEngine.collection) {
            try await syncSpaces(storage: storage, keys: keys, info: info)
        }
        if preferences.isEnabled(BookmarksEngine.collection) {
            try await syncBookmarks(storage: storage, keys: keys, info: info)
        }
        if preferences.isEnabled(TabsEngine.collection) {
            try await syncTabs(storage: storage, keys: keys, info: info)
        }
        if preferences.isEnabled(HistoryEngine.collection) {
            try await syncHistory(storage: storage, keys: keys, info: info)
        }
        try await syncClients(storage: storage, keys: keys, info: info)
    }

    // MARK: meta/global

    private func reconcileMetaGlobal(storage: SyncStorageClient, info: [String: Double])
        async throws
    {
        var meta: MetaGlobal
        var modified: Double?
        if let existing = try await storage.metaGlobal() {
            meta = existing.meta
            modified = existing.modified
            guard meta.storageVersion == SyncConfig.storageVersion else {
                throw SyncError.storageVersionUnsupported(meta.storageVersion)
            }
        } else {
            meta = MetaGlobal()
        }

        // A changed account-level syncID means the whole account was reset.
        if state.shadow.storageSyncID != meta.syncID {
            state.shadow.collections = [:]
            state.shadow.storageSyncID = meta.syncID
        }

        var changed = false
        for (name, version) in SyncConfig.engineVersions {
            if let engine = meta.engines[name] {
                // A changed engine syncID, or a version we do not speak, means
                // start that collection again from nothing.
                if state.shadow[name].syncID != engine.syncID {
                    var shadow = state.shadow[name]
                    shadow.reset(syncID: engine.syncID)
                    state.shadow[name] = shadow
                }
            } else if preferences.isEnabled(name) {
                let syncID = SyncGUID.generate()
                meta.engines[name] = MetaGlobal.EngineMeta(version: version, syncID: syncID)
                var shadow = state.shadow[name]
                shadow.reset(syncID: syncID)
                state.shadow[name] = shadow
                changed = true
            }
        }

        let declined = Set(preferences.declinedEngines)
        if Set(meta.declined) != declined {
            meta.declined = declined.sorted()
            changed = true
        }

        if changed {
            _ = try await storage.put(
                collection: "meta", id: "global",
                payload: try meta.json.serializedString(), unmodifiedSince: modified)
        }
    }

    // MARK: Spaces

    private func syncSpaces(
        storage: SyncStorageClient, keys: CollectionKeys, info: [String: Double]
    ) async throws {
        guard let browser, let bundle = keys.bundle(for: SpacesEngine.collection) else { return }
        var shadow = state.shadow[SpacesEngine.collection]

        // Stamp anything that changed while we were away, so the merge below
        // compares honest timestamps.
        var local = browser.spacesState
        SpacesEngine.journalLocalChanges(
            state: local, shadow: &shadow, identities: &state.shadow.identities,
            symbolShadow: &state.shadow.spaceSymbolShadow,
            syncNormalTabs: preferences.syncNormalTabs, now: now().timeIntervalSince1970)

        // Down.
        let remoteModified = info[SpacesEngine.collection] ?? 0
        if remoteModified > shadow.lastModified {
            let fetched = try await storage.fetch(
                collection: SpacesEngine.collection, bundle: bundle,
                newer: shadow.lastModified)
            if !fetched.records.isEmpty {
                SpacesEngine.applyIncoming(
                    fetched.records, to: &local, shadow: &shadow,
                    identities: &state.shadow.identities,
                    symbolShadow: &state.shadow.spaceSymbolShadow)
                browser.applySyncedSpacesState(local)
                local = browser.spacesState
            }
            shadow.lastModified = max(shadow.lastModified, fetched.modified)
        }

        // Up.
        let outgoing = SpacesEngine.outgoing(
            from: local, shadow: shadow, identities: &state.shadow.identities,
            symbolShadow: &state.shadow.spaceSymbolShadow,
            syncNormalTabs: preferences.syncNormalTabs)

        var records = outgoing.records
        records += outgoing.tombstones.map(SpacesEngine.tombstoneRecord(id:))

        if !records.isEmpty {
            let result = try await storage.post(
                collection: SpacesEngine.collection, records: records, bundle: bundle,
                unmodifiedSince: shadow.lastModified > 0 ? shadow.lastModified : nil)
            let succeeded = Set(result.success)
            for record in records where succeeded.contains(record.id) {
                if record.isDeleted {
                    shadow.noteApplied(id: record.id, payload: nil)
                    shadow.pendingDeletions[record.id] = nil
                } else {
                    shadow.noteUploaded(id: record.id, payload: record.payload)
                }
            }
            shadow.lastModified = max(shadow.lastModified, result.modified)
        }

        state.shadow[SpacesEngine.collection] = shadow
        state.shadow.identities.prune(
            keepingLocal: Set(local.spaces.map(\.id)).union(local.tabs.map(\.id)))
    }

    // MARK: Bookmarks

    private func syncBookmarks(
        storage: SyncStorageClient, keys: CollectionKeys, info: [String: Double]
    ) async throws {
        guard let browser, let bundle = keys.bundle(for: BookmarksEngine.collection) else {
            return
        }
        var shadow = state.shadow[BookmarksEngine.collection]

        let remoteModified = info[BookmarksEngine.collection] ?? 0
        if remoteModified > shadow.lastModified {
            let fetched = try await storage.fetch(
                collection: BookmarksEngine.collection, bundle: bundle,
                newer: shadow.lastModified)
            let result = BookmarksEngine.applyIncoming(
                fetched.records, into: browser.bookmarks.bookmarks, shadow: &shadow,
                identities: &state.shadow.identities)
            browser.bookmarks.applySynced(
                added: result.added, updated: result.updated, removedIDs: result.removedIDs)
            shadow.lastModified = max(shadow.lastModified, fetched.modified)
        }

        let outgoing = BookmarksEngine.outgoing(
            bookmarks: browser.bookmarks.bookmarks, shadow: shadow,
            identities: &state.shadow.identities)
        var records = outgoing.records
        records += outgoing.tombstones.map(SpacesEngine.tombstoneRecord(id:))
        if !records.isEmpty {
            let result = try await storage.post(
                collection: BookmarksEngine.collection, records: records, bundle: bundle,
                unmodifiedSince: shadow.lastModified > 0 ? shadow.lastModified : nil)
            let succeeded = Set(result.success)
            for record in records where succeeded.contains(record.id) {
                shadow.noteUploaded(id: record.id, payload: record.payload)
            }
            shadow.lastModified = max(shadow.lastModified, result.modified)
        }
        state.shadow[BookmarksEngine.collection] = shadow
    }

    // MARK: Tabs

    private func syncTabs(
        storage: SyncStorageClient, keys: CollectionKeys, info: [String: Double]
    ) async throws {
        guard let browser, let bundle = keys.bundle(for: TabsEngine.collection) else { return }
        var shadow = state.shadow[TabsEngine.collection]

        let ours = TabsEngine.outgoing(
            guid: state.shadow.clientGUID, clientName: effectiveDeviceName,
            tabs: browser.tabs, now: now())
        if shadow.uploaded[ours.id] != ours.payload.digest {
            let result = try await storage.post(
                collection: TabsEngine.collection, records: [ours], bundle: bundle,
                unmodifiedSince: nil)
            if result.success.contains(ours.id) {
                shadow.noteUploaded(id: ours.id, payload: ours.payload)
            }
            shadow.lastModified = max(shadow.lastModified, result.modified)
        }

        // Everyone else's, always — this is a view of other devices, so
        // "nothing changed here" is not a reason to skip it.
        let fetched = try await storage.fetch(collection: TabsEngine.collection, bundle: bundle)
        let clients = try await fetchClients(storage: storage, keys: keys)
        remoteTabs = TabsEngine.parse(
            fetched.records, ourGUID: state.shadow.clientGUID, clients: clients)
        state.remoteTabs = remoteTabs
        shadow.lastModified = max(shadow.lastModified, fetched.modified)
        state.shadow[TabsEngine.collection] = shadow
    }

    private func fetchClients(storage: SyncStorageClient, keys: CollectionKeys) async throws
        -> [String: SyncDeviceRecord]
    {
        guard let bundle = keys.bundle(for: ClientsEngine.collection) else { return [:] }
        let fetched = try await storage.fetch(
            collection: ClientsEngine.collection, bundle: bundle)
        var out: [String: SyncDeviceRecord] = [:]
        for record in fetched.records {
            if let client = SyncDeviceRecord.parse(record) { out[record.id] = client }
        }
        return out
    }

    // MARK: History

    private func syncHistory(
        storage: SyncStorageClient, keys: CollectionKeys, info: [String: Double]
    ) async throws {
        guard let browser, let bundle = keys.bundle(for: HistoryEngine.collection) else {
            return
        }
        var shadow = state.shadow[HistoryEngine.collection]

        let remoteModified = info[HistoryEngine.collection] ?? 0
        if remoteModified > shadow.lastModified {
            let fetched = try await storage.fetch(
                collection: HistoryEngine.collection, bundle: bundle,
                newer: shadow.lastModified, limit: 1000)
            let visits = HistoryEngine.applyIncoming(fetched.records, shadow: &shadow)
            browser.history.applySynced(visits)
            shadow.lastModified = max(shadow.lastModified, fetched.modified)
        }

        let records = HistoryEngine.outgoing(
            entries: browser.history.entries, shadow: shadow)
        if !records.isEmpty {
            let result = try await storage.post(
                collection: HistoryEngine.collection, records: records, bundle: bundle,
                unmodifiedSince: nil)
            let succeeded = Set(result.success)
            for record in records where succeeded.contains(record.id) {
                shadow.noteUploaded(id: record.id, payload: record.payload)
            }
            shadow.lastModified = max(shadow.lastModified, result.modified)
        }
        state.shadow[HistoryEngine.collection] = shadow
    }

    // MARK: Clients

    private func syncClients(
        storage: SyncStorageClient, keys: CollectionKeys, info: [String: Double]
    ) async throws {
        guard let bundle = keys.bundle(for: ClientsEngine.collection) else { return }
        var shadow = state.shadow[ClientsEngine.collection]
        let device = ClientsEngine.record(
            guid: state.shadow.clientGUID, name: effectiveDeviceName)
        let record = DecryptedRecord(id: device.guid, modified: 0, payload: device.json)
        guard shadow.uploaded[record.id] != record.payload.digest else { return }

        let result = try await storage.post(
            collection: ClientsEngine.collection, records: [record], bundle: bundle,
            unmodifiedSince: nil)
        if result.success.contains(record.id) {
            shadow.noteUploaded(id: record.id, payload: record.payload)
        }
        state.shadow[ClientsEngine.collection] = shadow
    }

    // MARK: Persistence

    private func persist() {
        state.preferences = preferences
        state.account = account
        state.lastSyncedAt = lastSyncedAt
        state.remoteTabs = remoteTabs
        file.save(state)
    }

    /// Exposed for the Settings screen's "Reset sync data on this device".
    func forgetSyncState() {
        state.shadow = SyncShadow()
        remoteTabs = []
        state.remoteTabs = []
        persist()
    }
}
