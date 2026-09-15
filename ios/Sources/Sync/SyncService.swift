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

    /// The step-by-step transcript of a sign-in and first sync (#008AA). Its
    /// own `ObservableObject` so the diagnostics screen can redraw on every
    /// line without republishing the whole service.
    let diagnostics = SyncDiagnostics()

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
    /// Non-nil while the sign-in sheet should be up. The view observes it.
    @Published private(set) var pendingSignIn: FxAAuthorizationRequest?
    /// True between `oauth_login` and the end of the exchange. The sheet's
    /// `item:` binding fires its setter when the sheet goes away, and without
    /// this that dismissal would call `cancelSignIn()` and stamp `.signedOut`
    /// over a sign-in that is halfway through succeeding.
    private var isCompletingSignIn = false
    private var syncTask: Task<Void, Never>?
    private var timer: Timer?
    private var lastAttemptAt: Date?
    /// Engines whose `meta/global` version is newer than the one we speak.
    /// Their records may mean something else entirely, so they are skipped
    /// rather than merged.
    private var unsupportedEngines: Set<String> = []

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

    /// Step one: build the authorization request and put the sheet up. The
    /// view layer owns the presentation — `SyncService` is not a view, and a
    /// service that reaches for the key window to present something is a
    /// service that cannot be tested.
    func beginSignIn(email: String? = nil) async {
        guard !status.isBusy else { return }
        status = .signingIn
        diagnostics.beginAttempt()
        do {
            // Discovery first: Mozilla moves hosts, and a stale constant is a
            // sign-in that fails for no visible reason.
            endpoints = await FxAOAuthClient.discoverEndpoints(transport: transport)
            diagnostics.log(
                .authorizeOpened,
                "endpoints: oauth \(endpoints.oauthServer.host ?? "?"), token "
                    + (endpoints.tokenServer.host ?? "?"))
            let client = FxAOAuthClient(endpoints: endpoints, transport: transport)

            if SyncConfig.usesSystemAuthSession {
                // Only reachable with a client id whose redirect is a custom
                // scheme — see SyncConfig. Kept working so the better path is
                // one constant away.
                let flow = FxASignInFlow()
                signInFlow = flow
                let tokens = try await flow.signIn(client: client, email: email)
                signInFlow = nil
                try await adopt(tokens: tokens, client: client)
                return
            }

            pendingSignIn = try client.authorizationRequest(email: email)
        } catch let error as SyncError {
            signInFlow = nil
            if error != .cancelled { diagnostics.failed(.authorizeOpened, error) }
            status = error == .cancelled ? .signedOut : .failed(error.localizedDescription)
        } catch {
            signInFlow = nil
            diagnostics.failed(.authorizeOpened, error)
            status = .failed(error.localizedDescription)
        }
    }

    /// Step two, the one that matters: the sheet handed us an
    /// `fxaccounts:oauth_login` over the WebChannel. Validate the state,
    /// exchange the code, and — if that works — we are signed in.
    func completeSignIn(login: FxAWebChannelOAuthLogin) async {
        guard let request = pendingSignIn else { return }
        await completeSignIn(request: request) { client in
            let code = try FxAOAuthClient.authorizationCode(
                fromWebChannel: login, expectedState: request.state)
            self.diagnostics.succeeded(.oauthLogin, "state matched")
            if !login.declinedSyncEngines.isEmpty {
                self.applyChooseWhatToSync(
                    declined: login.declinedSyncEngines, offered: login.offeredSyncEngines)
            }
            return try await client.exchange(code: code, request: request)
        }
    }

    /// The fallback path: a navigation to the registered redirect carried the
    /// code. Not what this client id does — see `FxAWebChannel.swift` — but it
    /// costs nothing to keep working.
    func completeSignIn(callback: URL) async {
        guard let request = pendingSignIn else { return }
        await completeSignIn(request: request) { client in
            let code = try FxAOAuthClient.authorizationCode(
                fromCallback: callback, expectedState: request.state)
            self.diagnostics.succeeded(.oauthLogin, "state matched (redirect)")
            return try await client.exchange(code: code, request: request)
        }
    }

    private func completeSignIn(
        request: FxAAuthorizationRequest,
        exchange: @escaping (FxAOAuthClient) async throws -> FxAOAuthTokens
    ) async {
        pendingSignIn = nil
        isCompletingSignIn = true
        defer { isCompletingSignIn = false }
        status = .signingIn
        do {
            let client = FxAOAuthClient(endpoints: endpoints, transport: transport)
            let tokens = try await exchange(client)
            diagnostics.succeeded(
                .codeExchange,
                SyncDiagnostics.shape(tokens.accessToken, label: "access token")
                    + ", refresh token "
                    + (tokens.refreshToken == nil ? "missing" : "present")
                    + ", scopes " + tokens.scopes.joined(separator: " "))
            try await adopt(tokens: tokens, client: client)
        } catch let error as SyncError {
            if error != .cancelled { diagnostics.failed(.codeExchange, error) }
            status = error == .cancelled ? .signedOut : .failed(error.localizedDescription)
        } catch {
            diagnostics.failed(.codeExchange, error)
            status = .failed(error.localizedDescription)
        }
    }

    func cancelSignIn() {
        // The sheet's dismissal fires this even when it was dismissed *by* a
        // successful login. Do not undo a sign-in that is in flight.
        guard !isCompletingSignIn else { return }
        pendingSignIn = nil
        signInFlow?.cancel()
        signInFlow = nil
        status = isSignedIn ? (preferences.enabled ? .idle : .paused) : .signedOut
    }

    /// Honour the "choose what to sync" checkboxes. Only engines the page
    /// actually offered are touched: `spaces` is Zen's own collection, it is
    /// never on that screen, and inferring "declined" from its absence would
    /// silently switch off the one engine this app exists for.
    private func applyChooseWhatToSync(declined: [String], offered: [String]) {
        let declinedSet = Set(declined)
        let offeredSet = Set(offered.isEmpty ? SyncConfig.webChannelEngines : offered)
        var adopted = preferences
        func apply(_ engine: String, _ keyPath: WritableKeyPath<SyncPreferences, Bool>) {
            guard offeredSet.contains(engine) else { return }
            adopted[keyPath: keyPath] = !declinedSet.contains(engine)
        }
        apply(BookmarksEngine.collection, \.syncBookmarks)
        apply(TabsEngine.collection, \.syncTabs)
        apply(HistoryEngine.collection, \.syncHistory)
        preferences = adopted
        diagnostics.log(
            .oauthLogin, "choose-what-to-sync: declined " + declined.joined(separator: ", "))
    }

    private func adopt(tokens: FxAOAuthTokens, client: FxAOAuthClient) async throws {
        guard let scopedKey = tokens.scopedKey else {
            diagnostics.failed(.keysDecrypted, SyncError.scopedKeyMissing)
            throw SyncError.scopedKeyMissing
        }
        diagnostics.succeeded(
            .keysDecrypted, "oldsync scoped key decrypted from keys_jwe, kid \(scopedKey.kid)")

        var secrets = SyncSecrets()
        secrets.refreshToken = tokens.refreshToken
        secrets.accessToken = tokens.accessToken
        secrets.accessTokenExpiresAt = tokens.expiresAt
        secrets.scopedKey = scopedKey
        self.secrets.save(secrets)

        // The profile is decoration; a failure here is not a failed sign-in.
        let profile = try? await client.profile(accessToken: tokens.accessToken)
        account = SyncAccountSummary(
            email: profile?.email, displayName: profile?.displayName, signedInAt: now())
        state.account = account
        state.lastError = nil
        persist()
        status = preferences.enabled ? .idle : .paused
        diagnostics.log(.firstSync, "starting")
        syncNow(reason: .signIn)
    }

    func signOut() async {
        pendingSignIn = nil
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
        diagnostics.log(.signedOut, "keys removed from this device")
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
        // Each piece is copied out and written back rather than passed as
        // `&state.shadow.…`: two inout arguments derived from the same stored
        // property overlap, and Swift's exclusivity checking traps on it.
        var shadow = state.shadow[SpacesEngine.collection]
        var identities = state.shadow.identities
        var symbols = state.shadow.spaceSymbolShadow
        SpacesEngine.journalLocalChanges(
            state: browser.spacesState, shadow: &shadow, identities: &identities,
            symbolShadow: &symbols, syncNormalTabs: preferences.syncNormalTabs,
            now: now().timeIntervalSince1970)
        state.shadow[SpacesEngine.collection] = shadow
        state.shadow.identities = identities
        state.shadow.spaceSymbolShadow = symbols
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
            diagnostics.succeeded(.firstSync, "completed")
            state.lastError = nil
            lastSyncedAt = now()
            state.lastSyncedAt = lastSyncedAt
            status = preferences.enabled ? .idle : .paused
        } catch let error as SyncError {
            switch error {
            case .backoff(let seconds):
                diagnostics.log(.firstSync, error.localizedDescription)
                status = .backingOff(until: now().addingTimeInterval(seconds))
            case .authenticationExpired:
                // The refresh token is gone or revoked. Keep the account row
                // so the owner can see *why* they are being asked again.
                diagnostics.failed(.firstSync, error)
                status = .failed(error.localizedDescription)
                state.lastError = error.localizedDescription
            default:
                diagnostics.failed(.firstSync, error)
                status = .failed(error.localizedDescription)
                state.lastError = error.localizedDescription
            }
        } catch is CancellationError {
            status = preferences.enabled ? .idle : .paused
        } catch {
            diagnostics.failed(.firstSync, error)
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
            diagnostics.log(.tokenServer, "requesting \(tokenClient.url.absoluteString)")
            do {
                token = try await tokenClient.token(
                    accessToken: accessToken, keyID: scopedKey.kid)
            } catch {
                diagnostics.failed(.tokenServer, error)
                throw error
            }
            secrets.token = token
            self.secrets.save(secrets)
            diagnostics.succeeded(.tokenServer, "allocated, uid \(token?.uid ?? 0)")
        }
        guard let token else { throw SyncError.authenticationExpired }
        diagnostics.succeeded(
            .storageNode, token.storageEndpoint.host ?? token.storageEndpoint.absoluteString)

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
        func shouldSync(_ collection: String) -> Bool {
            preferences.isEnabled(collection) && !unsupportedEngines.contains(collection)
        }
        if shouldSync(SpacesEngine.collection) {
            try await syncSpaces(storage: storage, keys: keys, info: info)
        }
        if shouldSync(BookmarksEngine.collection) {
            try await syncBookmarks(storage: storage, keys: keys, info: info)
        }
        if shouldSync(TabsEngine.collection) {
            try await syncTabs(storage: storage, keys: keys, info: info)
        }
        if shouldSync(HistoryEngine.collection) {
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
        let isFirstSyncWithThisAccount = state.shadow.storageSyncID.isEmpty
        if state.shadow.storageSyncID != meta.syncID {
            state.shadow.collections = [:]
            state.shadow.storageSyncID = meta.syncID
        }

        // On the first sync with an account, the account's engine choices win.
        // Publishing ours instead would let a phone silently turn off an
        // engine the desktop had deliberately declined.
        if isFirstSyncWithThisAccount && !meta.declined.isEmpty {
            adoptDeclined(meta.declined)
        }

        unsupportedEngines = []
        var changed = false
        for (name, version) in SyncConfig.engineVersions {
            if let engine = meta.engines[name] {
                // An engine version we do not speak is not ours to sync: the
                // records may mean something else entirely. Skip that
                // collection rather than corrupt it.
                if engine.version > version {
                    unsupportedEngines.insert(name)
                    continue
                }
                // A changed engine syncID means start that collection again
                // from nothing.
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

    private func adoptDeclined(_ declined: [String]) {
        var adopted = preferences
        let set = Set(declined)
        adopted.syncSpaces = !set.contains(SpacesEngine.collection)
        adopted.syncBookmarks = !set.contains(BookmarksEngine.collection)
        adopted.syncTabs = !set.contains(TabsEngine.collection)
        adopted.syncHistory = !set.contains(HistoryEngine.collection)
        preferences = adopted
    }

    // MARK: Spaces

    private func syncSpaces(
        storage: SyncStorageClient, keys: CollectionKeys, info: [String: Double]
    ) async throws {
        guard let browser, let bundle = keys.bundle(for: SpacesEngine.collection) else { return }
        var shadow = state.shadow[SpacesEngine.collection]
        var identities = state.shadow.identities
        var symbols = state.shadow.spaceSymbolShadow
        defer {
            state.shadow[SpacesEngine.collection] = shadow
            state.shadow.identities = identities
            state.shadow.spaceSymbolShadow = symbols
        }

        // Stamp anything that changed while we were away, so the merge below
        // compares honest timestamps.
        var local = browser.spacesState
        SpacesEngine.journalLocalChanges(
            state: local, shadow: &shadow, identities: &identities, symbolShadow: &symbols,
            syncNormalTabs: preferences.syncNormalTabs, now: now().timeIntervalSince1970)

        // Down.
        let remoteModified = info[SpacesEngine.collection] ?? 0
        if remoteModified > shadow.lastModified {
            let fetched = try await storage.fetch(
                collection: SpacesEngine.collection, bundle: bundle,
                newer: shadow.lastModified)
            if !fetched.records.isEmpty {
                SpacesEngine.applyIncoming(
                    fetched.records, to: &local, shadow: &shadow, identities: &identities,
                    symbolShadow: &symbols)
                browser.applySyncedSpacesState(local)
                local = browser.spacesState
            }
            shadow.lastModified = max(shadow.lastModified, fetched.modified)
        }

        // Up.
        let outgoing = SpacesEngine.outgoing(
            from: local, shadow: shadow, identities: &identities, symbolShadow: &symbols,
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

        identities.prune(
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
        var identities = state.shadow.identities
        defer {
            state.shadow[BookmarksEngine.collection] = shadow
            state.shadow.identities = identities
        }

        let remoteModified = info[BookmarksEngine.collection] ?? 0
        if remoteModified > shadow.lastModified {
            let fetched = try await storage.fetch(
                collection: BookmarksEngine.collection, bundle: bundle,
                newer: shadow.lastModified)
            let result = BookmarksEngine.applyIncoming(
                fetched.records, into: browser.bookmarks.bookmarks, shadow: &shadow,
                identities: &identities)
            browser.bookmarks.applySynced(
                added: result.added, updated: result.updated, removedIDs: result.removedIDs)
            shadow.lastModified = max(shadow.lastModified, fetched.modified)
        }

        let outgoing = BookmarksEngine.outgoing(
            bookmarks: browser.bookmarks.bookmarks, shadow: shadow, identities: &identities)
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

    /// Adopt an account without running the OAuth flow. Only a test can
    /// reach this: a real sign-in has to go through ASWebAuthenticationSession,
    /// which needs a human and a password.
    func adoptAccountForTesting(_ summary: SyncAccountSummary) {
        account = summary
        state.account = summary
        status = preferences.enabled ? .idle : .paused
    }

    /// Run one sync and wait for it to finish. The app fires and forgets;
    /// a test cannot, and neither can a pull-to-refresh.
    func syncAndWait(reason: SyncReason = .manual) async {
        syncNow(reason: reason)
        await syncTask?.value
    }

    /// Read-only access to the persisted shadow, for tests and for the
    /// Settings screen's diagnostics.
    var shadow: SyncShadow { state.shadow }

    /// Exposed for the Settings screen's "Reset sync data on this device".
    func forgetSyncState() {
        state.shadow = SyncShadow()
        remoteTabs = []
        state.remoteTabs = []
        persist()
    }
}
