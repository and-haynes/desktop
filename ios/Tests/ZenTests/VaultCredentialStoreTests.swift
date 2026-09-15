//  VaultCredentialStoreTests.swift
//  That what goes into the keychain comes back out (#008AD).
//
//  Written after a screenshot run found the gap the hard way: connecting a
//  vault succeeded, the settings screen showed the server and the account, and
//  the sync that followed reported "No password vault is set up yet". The
//  connection test passes its credentials in directly, while the sync reads
//  them back from the keychain — so a broken round trip looks exactly like a
//  working setup right up until the moment it matters.
//
//  Uses its own service name and clears up after itself: the simulator's
//  keychain is shared by every test in the process and by the app itself, so a
//  test writing to the real service would sign the developer's own vault out.

import XCTest

@testable import Zen

final class VaultCredentialStoreTests: XCTestCase {

    private let service = "app.zen.passwords.tests"
    private var store: KeychainVaultCredentialStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            KeychainVaultCredentialStore.isAvailable,
            "this build has no keychain entitlement — every SecItem call returns -34018. "
                + "Drop CODE_SIGNING_ALLOWED=NO to run these.")
        store = KeychainVaultCredentialStore(service: service)
        store.clearCredentials()
        store.clearIndexKey()
    }

    override func tearDown() {
        store?.clearCredentials()
        store?.clearIndexKey()
        store = nil
        super.tearDown()
    }

    func testCredentialsSurviveARoundTrip() throws {
        XCTAssertNil(store.loadCredentials(), "the keychain was not clean to start with")

        store.saveCredentials(VaultCredentials(masterPassword: "correct-horse"))
        let loaded = try XCTUnwrap(
            store.loadCredentials(), "nothing came back out of the keychain")
        XCTAssertEqual(loaded.masterPassword, "correct-horse")
        XCTAssertNil(loaded.connectToken)
        XCTAssertFalse(loaded.isEmpty)
    }

    /// The path that broke: saving twice. The first write is an add, the second
    /// has to be an update — and an update that silently fails leaves the first
    /// value in place, or none at all.
    func testSavingTwiceUpdatesRatherThanFailing() throws {
        store.saveCredentials(VaultCredentials(masterPassword: "first"))
        store.saveCredentials(VaultCredentials(masterPassword: "second"))
        let loaded = try XCTUnwrap(store.loadCredentials())
        XCTAssertEqual(loaded.masterPassword, "second")
    }

    func testAConnectTokenRoundTripsToo() throws {
        store.saveCredentials(VaultCredentials(connectToken: "ops_abc123"))
        let loaded = try XCTUnwrap(store.loadCredentials())
        XCTAssertEqual(loaded.connectToken, "ops_abc123")
        XCTAssertNil(loaded.masterPassword)
    }

    func testClearingRemovesThem() {
        store.saveCredentials(VaultCredentials(masterPassword: "x"))
        XCTAssertNotNil(store.loadCredentials())
        store.clearCredentials()
        XCTAssertNil(store.loadCredentials())
    }

    /// The index key is minted once and then stable — a key that changed per
    /// call would make every cached index unreadable on the next launch.
    func testTheIndexKeyIsMintedOnceAndStable() throws {
        let first = try XCTUnwrap(store.indexKey(), "the keychain would not mint an index key")
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(store.indexKey(), first)
        XCTAssertEqual(KeychainVaultCredentialStore(service: service).indexKey(), first)
    }

    func testTheIndexKeyAndTheCredentialsAreSeparateItems() throws {
        store.saveCredentials(VaultCredentials(masterPassword: "x"))
        let key = try XCTUnwrap(store.indexKey())
        store.clearCredentials()
        XCTAssertNil(store.loadCredentials())
        XCTAssertEqual(store.indexKey(), key, "clearing the credentials took the index key too")
    }
}
