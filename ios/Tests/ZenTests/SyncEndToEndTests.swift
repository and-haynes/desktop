//  SyncEndToEndTests.swift
//  A whole sync, against a Sync 1.5 server that only ever sees ciphertext.
//
//  These are the tests that would have caught the interesting bugs: a record
//  that encrypts but does not decrypt, a schema the desktop would not
//  recognise, a second sync that re-uploads everything, a merge that loses a
//  space. The mock server stores opaque payloads, so every assertion below
//  went through our own encrypt *and* our own decrypt.

import XCTest

@testable import Zen

@MainActor
final class SyncEndToEndTests: XCTestCase {

    private var server: MockSyncServer!
    private var syncKey: SyncKeyBundle!
    private var collectionKeys: CollectionKeys!
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        server = MockSyncServer()
        syncKey = SyncKeyBundle(keyMaterial: Data(repeating: 0x5e, count: 64))!
        collectionKeys = CollectionKeys.generate()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-sync-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        // A server that already has keys — the state after any other client
        // has ever signed in.
        try server.seedEncrypted(
            collection: "crypto", id: "keys", payload: collectionKeys.json, bundle: syncKey)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: Fixtures

    /// Signed in, with a token that has not expired — so a sync goes straight
    /// to the storage server without an OAuth round trip we cannot fake.
    private func signedInSecrets() -> InMemorySecretStore {
        var secrets = SyncSecrets()
        secrets.accessToken = "access-token"
        secrets.accessTokenExpiresAt = Date().addingTimeInterval(3600)
        secrets.refreshToken = "refresh-token"
        secrets.scopedKey = ScopedKey(
            scope: SyncKeyBundle.oldSyncScope,
            keyMaterial: syncKey.encryptionKey + syncKey.hmacKey,
            kid: "1700000000000-" + SyncKeyBundle.fingerprint(
                ofKeyMaterial: syncKey.encryptionKey + syncKey.hmacKey))
        secrets.token = server.token()
        return InMemorySecretStore(secrets)
    }

    private func makeService(name: String = "sync-state.json") -> SyncService {
        let service = SyncService(
            file: JSONFileStore<SyncStateFile>(name: name, directory: directory),
            secrets: signedInSecrets(), transport: server)
        // The service only syncs once it believes it is signed in, which
        // normally happens at the end of the OAuth flow.
        service.adoptAccountForTesting(
            SyncAccountSummary(email: "andy@example.com", displayName: "Andy", signedInAt: Date())
        )
        return service
    }

    private func browser() -> BrowserState {
        BrowserState(
            session: SessionStore(
                file: JSONFileStore<SessionSnapshot>(
                    name: "session-\(UUID().uuidString).json", directory: directory)),
            history: HistoryStore(
                file: JSONFileStore<[HistoryEntry]>(
                    name: "history-\(UUID().uuidString).json", directory: directory)),
            bookmarks: BookmarkStore(
                file: JSONFileStore<[Bookmark]>(
                    name: "bookmarks-\(UUID().uuidString).json", directory: directory)),
            restore: false)
    }

    private func spacesBundle() -> SyncKeyBundle {
        collectionKeys.bundle(for: SpacesEngine.collection)!
    }

    /// A record as Zen desktop would have written it.
    private func seedDesktopSpace(
        id: String, name: String, icon: String, tabs: [(id: String, url: String, title: String)],
        modified: Double
    ) throws {
        let children = tabs.map { "\"\($0.id)\"" }.joined(separator: ",")
        try server.seedEncrypted(
            collection: SpacesEngine.collection, id: id,
            payload: try JSONValue(
                jsonString: """
                    {"id":"\(id)","kind":"space","data":{"uuid":"\(id)","name":"\(name)",
                     "icon":"\(icon)","theme":null,"containerGuid":null,
                     "children":[\(children)]}}
                    """),
            bundle: spacesBundle(), modified: modified)
        for tab in tabs {
            try server.seedEncrypted(
                collection: SpacesEngine.collection, id: tab.id,
                payload: try JSONValue(
                    jsonString: """
                        {"id":"\(tab.id)","kind":"tab","data":{"tabId":"\(tab.id)",
                         "url":"\(tab.url)","title":"\(tab.title)","icon":"",
                         "containerGuid":null,"essential":false,"pinned":true,
                         "workspaceUuid":"\(id)","folderId":null,"staticLabel":null,
                         "hasStaticIcon":false,"defaultContainer":false}}
                        """),
                bundle: spacesBundle(), modified: modified + 0.01)
        }
    }

    // MARK: Tests

    /// The first sync of a phone against an account the desktop already uses.
    func testDesktopSpacesArriveOnThePhone() async throws {
        try seedDesktopSpace(
            id: "{aabbccdd-1122-3344-5566-778899aabbcc}", name: "Reading", icon: "📚",
            tabs: [("1757894400000-7", "https://lobste.rs/", "Lobsters")],
            modified: 1000)

        let browser = browser()
        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()

        XCTAssertEqual(service.status, .idle, service.status.summary)
        XCTAssertTrue(
            browser.spaces.contains { $0.name == "Reading" && $0.icon == "📚" },
            browser.spaces.map(\.name).description)

        let tab = try XCTUnwrap(browser.tabs.first { $0.title == "Lobsters" })
        XCTAssertEqual(tab.kind, .pinned)
        XCTAssertEqual(tab.url.absoluteString, "https://lobste.rs/")
        XCTAssertEqual(
            browser.spaces.first { $0.name == "Reading" }?.id, tab.spaceID)
    }

    /// …and the reverse: what the phone writes is in the desktop's schema.
    func testPhoneSpacesReachTheServerInTheDesktopSchema() async throws {
        let browser = browser()
        let space = browser.addSpace(
            name: "Homelab", icon: "🖥", isSymbol: false, theme: .default)
        browser.newTab(url: URL(string: "https://refs.lan/")!, in: space.id)
        browser.togglePinned(browser.tabs.last!.id)

        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()
        XCTAssertEqual(service.status, .idle, service.status.summary)

        let records = try server.decryptedRecords(
            in: SpacesEngine.collection, bundle: spacesBundle())
        let spaceRecord = try XCTUnwrap(
            records.first { $0.data?["name"]?.stringValue == "Homelab" })

        XCTAssertEqual(spaceRecord.kind, "space")
        // Braces, lowercase — the desktop's own uuid format.
        XCTAssertTrue(spaceRecord.id.hasPrefix("{") && spaceRecord.id.hasSuffix("}"))
        XCTAssertEqual(spaceRecord.id, spaceRecord.data?["uuid"]?.stringValue)
        XCTAssertEqual(spaceRecord.id.lowercased(), spaceRecord.id)

        let tabRecord = try XCTUnwrap(
            records.first {
                $0.kind == "tab" && $0.data?["url"]?.stringValue == "https://refs.lan/"
            })
        XCTAssertEqual(tabRecord.data?["pinned"]?.boolValue, true)
        XCTAssertEqual(tabRecord.data?["essential"]?.boolValue, false)
        XCTAssertEqual(tabRecord.data?["workspaceUuid"]?.stringValue, spaceRecord.id)
        // The space lists the tab as a child, in strip order.
        XCTAssertEqual(
            spaceRecord.data?["children"]?.arrayValue?.compactMap(\.stringValue),
            [tabRecord.id])

        // And the layout record, which carries the space order.
        let layout = try XCTUnwrap(records.first { $0.id == ZenSpacesRecords.layoutRecordID })
        XCTAssertEqual(layout.kind, "layout")
        XCTAssertTrue(
            layout.data?["spaces"]?.arrayValue?.compactMap(\.stringValue)
                .contains(spaceRecord.id) == true)
        XCTAssertNotNil(layout.data?["essentials"]?["default"])
    }

    /// The property that matters most for a phone's battery and data plan: a
    /// second sync with nothing changed writes nothing at all.
    func testSecondSyncUploadsNothing() async throws {
        let browser = browser()
        browser.addSpace(name: "Homelab", icon: "🖥", isSymbol: false, theme: .default)

        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()

        let after = server.timestamp(of: SpacesEngine.collection)
        let requestsBefore = server.requests.count

        await service.syncAndWait()
        XCTAssertEqual(service.status, .idle, service.status.summary)
        XCTAssertEqual(server.timestamp(of: SpacesEngine.collection), after)
        // Some requests are unavoidable (info/collections, other devices'
        // tabs) — but no POST to the spaces collection.
        let posts = server.requests.dropFirst(requestsBefore).filter {
            $0.httpMethod == "POST"
                && ($0.url?.path.contains("storage/\(SpacesEngine.collection)") ?? false)
        }
        XCTAssertTrue(posts.isEmpty, "a no-op sync must not write")
    }

    /// Both ends changed something different. Both changes survive.
    func testTwoWayMerge() async throws {
        try seedDesktopSpace(
            id: "{aabbccdd-1122-3344-5566-778899aabbcc}", name: "Reading", icon: "📚",
            tabs: [], modified: 1000)

        let browser = browser()
        browser.addSpace(name: "Homelab", icon: "🖥", isSymbol: false, theme: .default)

        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()
        XCTAssertEqual(service.status, .idle, service.status.summary)

        XCTAssertTrue(browser.spaces.contains { $0.name == "Reading" })
        XCTAssertTrue(browser.spaces.contains { $0.name == "Homelab" })

        let records = try server.decryptedRecords(
            in: SpacesEngine.collection, bundle: spacesBundle())
        let names = records.compactMap { $0.data?["name"]?.stringValue }
        XCTAssertTrue(names.contains("Reading"))
        XCTAssertTrue(names.contains("Homelab"))
    }

    /// A space renamed on the desktop after we last synced wins; the phone
    /// does not argue with a change it has not contradicted.
    func testDesktopRenameReachesThePhoneOnTheSecondSync() async throws {
        let id = "{aabbccdd-1122-3344-5566-778899aabbcc}"
        try seedDesktopSpace(id: id, name: "Reading", icon: "📚", tabs: [], modified: 1000)

        let browser = browser()
        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()
        XCTAssertTrue(browser.spaces.contains { $0.name == "Reading" })

        // The desktop's write lands after ours did, which is what the
        // server's own clock would have produced.
        let later = (server.timestamp(of: SpacesEngine.collection) ?? 0) + 100
        try seedDesktopSpace(id: id, name: "Longreads", icon: "📚", tabs: [], modified: later)
        await service.syncAndWait(reason: .manual)

        XCTAssertTrue(
            browser.spaces.contains { $0.name == "Longreads" },
            browser.spaces.map(\.name).description)
        XCTAssertFalse(browser.spaces.contains { $0.name == "Reading" })
    }

    /// A folder record — something this app cannot draw — must come back out
    /// of the server untouched, not be tombstoned by our silence about it.
    func testForeignRecordsSurviveASync() async throws {
        try server.seedEncrypted(
            collection: SpacesEngine.collection, id: "folder-1",
            payload: try JSONValue(
                jsonString:
                    #"{"id":"folder-1","kind":"folder","data":{"folderId":"folder-1","name":"Recipes","children":[]}}"#
            ),
            bundle: spacesBundle(), modified: 1000)

        let browser = browser()
        browser.addSpace(name: "Homelab", icon: "🖥", isSymbol: false, theme: .default)
        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()
        await service.syncAndWait(reason: .manual)

        let records = try server.decryptedRecords(
            in: SpacesEngine.collection, bundle: spacesBundle())
        let folder = try XCTUnwrap(records.first { $0.id == "folder-1" })
        XCTAssertFalse(folder.isDeleted)
        XCTAssertEqual(folder.data?["name"]?.stringValue, "Recipes")
    }

    /// meta/global has to end up with Zen's engine at the version the desktop
    /// expects, or the desktop wipes the collection.
    func testMetaGlobalDeclaresTheSpacesEngine() async throws {
        let browser = browser()
        browser.addSpace(name: "Homelab", icon: "🖥", isSymbol: false, theme: .default)
        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()

        let bso = try XCTUnwrap(server.records(in: "meta").first { $0.id == "global" })
        let meta = MetaGlobal(json: try JSONValue(jsonString: bso.payload))
        XCTAssertEqual(meta.storageVersion, 5)
        XCTAssertEqual(meta.engines["spaces"]?.version, 3)
        XCTAssertEqual(meta.engines["bookmarks"]?.version, 2)
        XCTAssertFalse(meta.engines["spaces"]?.syncID.isEmpty ?? true)
    }

    /// Turning an engine off puts it in `declined`, which is the same list the
    /// desktop's own Settings screen reads.
    func testDecliningAnEngineIsPublished() async throws {
        let browser = browser()
        let service = makeService()
        service.attach(to: browser)
        service.preferences.syncHistory = false
        await service.syncAndWait()

        let bso = try XCTUnwrap(server.records(in: "meta").first { $0.id == "global" })
        let meta = MetaGlobal(json: try JSONValue(jsonString: bso.payload))
        XCTAssertTrue(meta.declined.contains("history"))
        XCTAssertFalse(meta.declined.contains("spaces"))
        XCTAssertTrue(server.records(in: "history").isEmpty)
    }

    /// The clients record is what makes this phone visible to every other
    /// device in the account.
    func testClientRecordIsPublished() async throws {
        let browser = browser()
        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()

        let bundle = collectionKeys.bundle(for: ClientsEngine.collection)!
        let records = try server.decryptedRecords(in: ClientsEngine.collection, bundle: bundle)
        let device = try XCTUnwrap(records.first.flatMap(SyncDeviceRecord.parse))
        XCTAssertEqual(device.type, "mobile")
        XCTAssertEqual(device.os, "iOS")
        XCTAssertEqual(device.application, "Zen")
        XCTAssertFalse(device.name.isEmpty)
    }

    /// Another device's open tabs are shown, not adopted.
    func testOtherDevicesTabsAreReadIntoTheSidebar() async throws {
        let clientsBundle = collectionKeys.bundle(for: ClientsEngine.collection)!
        try server.seedEncrypted(
            collection: ClientsEngine.collection, id: "desktop-guid",
            payload: try JSONValue(
                jsonString:
                    #"{"id":"desktop-guid","name":"faraday","type":"desktop","os":"Linux"}"#),
            bundle: clientsBundle, modified: 900)
        try server.seedEncrypted(
            collection: TabsEngine.collection, id: "desktop-guid",
            payload: try JSONValue(
                jsonString: """
                    {"id":"desktop-guid","clientName":"faraday","tabs":[
                      {"title":"Lobsters","urlHistory":["https://lobste.rs/"],
                       "icon":"","lastUsed":1757894400}]}
                    """),
            bundle: collectionKeys.bundle(for: TabsEngine.collection)!, modified: 1000)

        let browser = browser()
        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()

        let device = try XCTUnwrap(service.remoteTabs.first)
        XCTAssertEqual(device.clientName, "faraday")
        XCTAssertEqual(device.deviceType, "desktop")
        XCTAssertEqual(device.symbol, "desktopcomputer")
        XCTAssertEqual(device.tabs.map(\.displayTitle), ["Lobsters"])
        // Shown, not adopted.
        XCTAssertFalse(browser.tabs.contains { $0.url.host == "lobste.rs" })
    }

    func testOurOwnTabsArePublished() async throws {
        let browser = browser()
        let space = browser.addSpace(
            name: "Homelab", icon: "🖥", isSymbol: false, theme: .default)
        browser.newTab(url: URL(string: "https://refs.lan/")!, in: space.id)

        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()

        let records = try server.decryptedRecords(
            in: TabsEngine.collection, bundle: collectionKeys.bundle(for: TabsEngine.collection)!)
        let ours = try XCTUnwrap(records.first)
        let urls = (ours.payload["tabs"]?.arrayValue ?? []).compactMap {
            $0["urlHistory"]?.arrayValue?.first?.stringValue
        }
        XCTAssertTrue(urls.contains("https://refs.lan/"))
        // The new-tab placeholder is not a tab anyone else wants to see.
        XCTAssertFalse(urls.contains(Tab.newTabURL.absoluteString))
    }

    func testBookmarksRoundTrip() async throws {
        let bookmarksBundle = collectionKeys.bundle(for: BookmarksEngine.collection)!
        try server.seedEncrypted(
            collection: BookmarksEngine.collection, id: "aaaaaaaaaaaa",
            payload: try JSONValue(
                jsonString: """
                    {"id":"aaaaaaaaaaaa","type":"bookmark","title":"Lobsters",
                     "bmkUri":"https://lobste.rs/","parentid":"toolbar",
                     "parentName":"toolbar","dateAdded":1700000000000,"tags":[]}
                    """),
            bundle: bookmarksBundle, modified: 1000)

        let browser = browser()
        browser.bookmarks.toggle(
            url: URL(string: "https://refs.lan/")!, title: "refs", spaceID: nil)

        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()

        // Down: the desktop's bookmark is here.
        XCTAssertTrue(browser.bookmarks.bookmarks.contains { $0.title == "Lobsters" })

        // Up: ours is on the server, filed under the mobile root, which lists it.
        let records = try server.decryptedRecords(
            in: BookmarksEngine.collection, bundle: bookmarksBundle)
        let ours = try XCTUnwrap(
            records.first { $0.payload["bmkUri"]?.stringValue == "https://refs.lan/" })
        XCTAssertEqual(ours.payload["type"]?.stringValue, "bookmark")
        XCTAssertEqual(ours.payload["parentid"]?.stringValue, "mobile")
        XCTAssertTrue(SyncGUID.isValid(ours.id))

        let root = try XCTUnwrap(records.first { $0.id == "mobile" })
        XCTAssertEqual(root.payload["type"]?.stringValue, "folder")
        XCTAssertTrue(
            root.payload["children"]?.arrayValue?.compactMap(\.stringValue).contains(ours.id)
                == true)
    }

    func testHistoryRoundTrip() async throws {
        let historyBundle = collectionKeys.bundle(for: HistoryEngine.collection)!
        try server.seedEncrypted(
            collection: HistoryEngine.collection, id: "bbbbbbbbbbbb",
            payload: try JSONValue(
                jsonString: """
                    {"id":"bbbbbbbbbbbb","histUri":"https://lobste.rs/","title":"Lobsters",
                     "visits":[{"date":1757894400000000,"type":1}]}
                    """),
            bundle: historyBundle, modified: 1000)

        let browser = browser()
        browser.history.record(url: URL(string: "https://refs.lan/")!, title: "refs")

        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()

        let incoming = try XCTUnwrap(
            browser.history.entries.first { $0.url.absoluteString == "https://lobste.rs/" })
        XCTAssertEqual(incoming.title, "Lobsters")
        // Microseconds, not milliseconds — the classic way history lands in 1970.
        XCTAssertEqual(
            incoming.lastVisited.timeIntervalSince1970, 1_757_894_400, accuracy: 1)

        let records = try server.decryptedRecords(
            in: HistoryEngine.collection, bundle: historyBundle)
        XCTAssertTrue(
            records.contains { $0.payload["histUri"]?.stringValue == "https://refs.lan/" })
    }

    /// A brand-new account has no crypto/keys, and nothing may be written
    /// until it does — otherwise the next client cannot read a thing.
    func testEmptyAccountGetsFreshCryptoKeys() async throws {
        server = MockSyncServer()
        let browser = browser()
        let service = makeService(name: "fresh.json")
        service.attach(to: browser)
        await service.syncAndWait()
        XCTAssertEqual(service.status, .idle, service.status.summary)

        let bso = try XCTUnwrap(server.records(in: "crypto").first { $0.id == "keys" })
        let payload = try JSONDecoder().decode(EncryptedPayload.self, from: Data(bso.payload.utf8))
        let keys = try XCTUnwrap(
            CollectionKeys(json: try BSOCrypto.decryptJSON(payload, with: syncKey)))
        XCTAssertNotNil(keys.bundle(for: SpacesEngine.collection))

        // …and the records that were written are readable with them.
        let records = try server.decryptedRecords(
            in: SpacesEngine.collection, bundle: keys.bundle(for: SpacesEngine.collection)!)
        XCTAssertFalse(records.isEmpty)
    }

    /// Storage the account uses a newer format for is refused rather than
    /// mangled.
    func testUnsupportedStorageVersionStopsTheSync() async throws {
        server.seed(
            collection: "meta", id: "global",
            payload: #"{"syncID":"abcdefghijkl","storageVersion":6,"engines":{},"declined":[]}"#,
            modified: 900)

        let browser = browser()
        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()

        guard case .failed(let message) = service.status else {
            return XCTFail("expected a refusal, got \(service.status)")
        }
        XCTAssertTrue(message.contains("storage format 6"), message)
        XCTAssertTrue(server.records(in: SpacesEngine.collection).isEmpty)
    }

    /// Pausing sync means pausing it.
    func testDisabledSyncDoesNothing() async throws {
        let browser = browser()
        browser.addSpace(name: "Homelab", icon: "🖥", isSymbol: false, theme: .default)
        let service = makeService()
        service.attach(to: browser)
        service.preferences.enabled = false
        await service.syncAndWait()
        XCTAssertTrue(server.records(in: SpacesEngine.collection).isEmpty)
        XCTAssertEqual(service.status, .paused)
    }

    /// A backoff is reported as such — it is the server being busy, not the
    /// account being broken, and the difference matters to whoever reads it.
    func testBackoffIsReportedNotTreatedAsAFailure() async throws {
        server.scriptedResponses = [
            HTTPResponse(status: 503, headers: ["Retry-After": "300"], body: Data())
        ]
        let browser = browser()
        let service = makeService()
        service.attach(to: browser)
        await service.syncAndWait()

        guard case .backingOff = service.status else {
            return XCTFail("expected a backoff, got \(service.status)")
        }
    }
}
