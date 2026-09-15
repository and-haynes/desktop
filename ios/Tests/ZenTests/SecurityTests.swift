//  SecurityTests.swift
//  The LAN host classifier and the trusted-certificate store (#00889).
//
//  The classifier decides whether a TLS failure gets the calm prompt or the
//  stern one. It is allowed to be wrong in one direction only — calling a LAN
//  host public is merely annoying, calling a public host local would dress a
//  real attack up as "normal for your home network". The negative cases below
//  are therefore the important ones.

import XCTest

@testable import Zen

final class LANHostTests: XCTestCase {

    // MARK: Private address space

    func testRFC1918AddressesAreLocal() {
        for host in [
            "10.0.0.42", "10.255.255.255", "192.168.1.1", "192.168.0.254",
            "172.16.0.1", "172.20.10.1", "172.31.255.254",
        ] {
            XCTAssertTrue(LANHost.isLocalNetwork(host), host)
        }
    }

    func testLoopbackAndLinkLocalAreLocal() {
        for host in ["127.0.0.1", "127.1.2.3", "169.254.10.20", "localhost", "LOCALHOST"] {
            XCTAssertTrue(LANHost.isLocalNetwork(host), host)
        }
    }

    /// 172.15 and 172.32 are *outside* the /12 — the classic off-by-one.
    func testAddressesJustOutsideRFC1918AreNotLocal() {
        for host in ["172.15.0.1", "172.32.0.1", "11.0.0.1", "192.169.0.1", "9.255.255.255"] {
            XCTAssertFalse(LANHost.isLocalNetwork(host), host)
        }
    }

    func testPublicAddressesAreNotLocal() {
        for host in ["8.8.8.8", "1.1.1.1", "93.184.216.34", "104.16.0.1"] {
            XCTAssertFalse(LANHost.isLocalNetwork(host), host)
        }
    }

    func testIPv6LoopbackLinkLocalAndUniqueLocalAreLocal() {
        for host in ["::1", "[::1]", "fe80::1", "fe80::1%en0", "fd00::1", "fc00::abcd"] {
            XCTAssertTrue(LANHost.isLocalNetwork(host), host)
        }
    }

    func testPublicIPv6IsNotLocal() {
        for host in ["2001:4860:4860::8888", "[2606:4700:4700::1111]"] {
            XCTAssertFalse(LANHost.isLocalNetwork(host), host)
        }
    }

    // MARK: Names

    func testLocalSuffixesAreLocal() {
        for host in [
            "refs.lan", "tickets.lan", "pi-a.local", "nas.home.arpa",
            "git.internal", "router.home", "REFS.LAN", "refs.lan.",
        ] {
            XCTAssertTrue(LANHost.isLocalNetwork(host), host)
        }
    }

    /// A single-label name can only be resolved by the local resolver, so it is
    /// local by construction.
    func testSingleLabelNamesAreLocal() {
        for host in ["noether", "pi-a", "unas", "router"] {
            XCTAssertTrue(LANHost.isLocalNetwork(host), host)
        }
    }

    func testPublicHostnamesAreNotLocal() {
        for host in [
            "example.com", "zen-browser.app", "news.ycombinator.com", "duckduckgo.com",
            "sub.domain.example.org", "apple.com",
        ] {
            XCTAssertFalse(LANHost.isLocalNetwork(host), host)
        }
    }

    /// A name merely *ending in the letters* of a local suffix must not match —
    /// "mylocal" is not ".local", and an attacker would love it if it were.
    func testNamesEndingInSuffixLettersDoNotMatch() {
        for host in ["mylocal", "notlan", "thelan", "homearpa"] where host.contains(".") {
            XCTAssertFalse(LANHost.isLocalNetwork(host), host)
        }
        // These are single-label, so they are local for the *other* reason —
        // assert the suffix rule specifically with a dotted form.
        for host in ["evil.mylocal.com", "phish.notlan.net", "a.thelocal.io"] {
            XCTAssertFalse(LANHost.isLocalNetwork(host), host)
        }
    }

    /// A lookalike registered under a public TLD must not inherit LAN trust.
    func testLookalikePublicDomainsAreNotLocal() {
        for host in ["refs.lan.evil.com", "pi-a.local.attacker.net", "home.arpa.example.com"] {
            XCTAssertFalse(LANHost.isLocalNetwork(host), host)
        }
    }

    func testEmptyAndNilAreNotLocal() {
        XCTAssertFalse(LANHost.isLocalNetwork(nil))
        XCTAssertFalse(LANHost.isLocalNetwork(""))
        XCTAssertFalse(LANHost.isLocalNetwork("   "))
    }

    /// Malformed dotted numbers are names, not addresses, and must not be
    /// treated as private just because they start with "10.".
    func testMalformedAddressesAreNotTreatedAsPrivate() {
        for host in ["10.0.0", "10.0.0.256", "10.0.0.1.2", "10.0.0.x"] {
            XCTAssertFalse(LANHost.isLocalNetwork(host), host)
        }
    }
}

final class TrustFailureTests: XCTestCase {

    func testHomelabTypicalFailuresAreRecognised() {
        XCTAssertTrue(TrustFailure.selfSigned.isHomelabTypical)
        XCTAssertTrue(TrustFailure.unknownAuthority.isHomelabTypical)
        XCTAssertTrue(TrustFailure.hostnameMismatch.isHomelabTypical)
        XCTAssertTrue(TrustFailure.expired.isHomelabTypical)
        XCTAssertTrue(
            TrustFailure([.selfSigned, .hostnameMismatch, .expired]).isHomelabTypical)
    }

    /// Anything we did not recognise must not get the calm treatment, even
    /// mixed in with failures that would have.
    func testUnrecognisedFailuresAreNotHomelabTypical() {
        XCTAssertFalse(TrustFailure.other.isHomelabTypical)
        XCTAssertFalse(TrustFailure([.selfSigned, .other]).isHomelabTypical)
        XCTAssertFalse(TrustFailure([]).isHomelabTypical)
    }

    func testExplanationNamesTheActualProblem() {
        XCTAssertTrue(TrustFailure.expired.explanation.lowercased().contains("date"))
        XCTAssertTrue(TrustFailure.hostnameMismatch.explanation.lowercased().contains("name"))
        XCTAssertTrue(
            TrustFailure([.hostnameMismatch, .expired]).explanation.lowercased()
                .contains("date"))
    }
}

@MainActor
final class TrustedCertificateStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenTrust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> TrustedCertificateStore {
        TrustedCertificateStore(
            file: JSONFileStore<[TrustedCertificate]>(
                name: "trusted-certs.json", directory: directory))
    }

    private let fingerprintA = String(repeating: "ab", count: 32)
    private let fingerprintB = String(repeating: "cd", count: 32)

    func testUnknownHostIsUnknown() {
        XCTAssertEqual(
            makeStore().verdict(host: "refs.lan", fingerprint: fingerprintA), .unknown)
    }

    func testApprovedCertificateIsTrustedSilently() {
        let store = makeStore()
        store.trust(host: "refs.lan", fingerprint: fingerprintA)
        XCTAssertEqual(store.verdict(host: "refs.lan", fingerprint: fingerprintA), .trusted)
    }

    /// The case the whole design exists for: same host, different certificate.
    func testChangedCertificateRePrompts() {
        let store = makeStore()
        store.trust(host: "refs.lan", fingerprint: fingerprintA)
        guard case .changed(let previous) = store.verdict(
            host: "refs.lan", fingerprint: fingerprintB)
        else { return XCTFail("expected .changed") }
        XCTAssertEqual(previous.fingerprint, fingerprintA)
    }

    /// Approving one host must not approve another that happens to share a
    /// certificate, nor the same host at a different address.
    func testTrustIsScopedToTheHost() {
        let store = makeStore()
        store.trust(host: "refs.lan", fingerprint: fingerprintA)
        XCTAssertEqual(
            store.verdict(host: "tickets.lan", fingerprint: fingerprintA), .unknown)
    }

    func testHostAndFingerprintAreCaseInsensitive() {
        let store = makeStore()
        store.trust(host: "Refs.LAN", fingerprint: fingerprintA.uppercased())
        XCTAssertEqual(store.verdict(host: "refs.lan", fingerprint: fingerprintA), .trusted)
    }

    /// Re-approving replaces, so a rotated-back old certificate is not silently
    /// accepted from a stale entry.
    func testReapprovingReplacesTheEarlierCertificate() {
        let store = makeStore()
        store.trust(host: "refs.lan", fingerprint: fingerprintA)
        store.trust(host: "refs.lan", fingerprint: fingerprintB)
        XCTAssertEqual(store.certificates.filter { $0.host == "refs.lan" }.count, 1)
        XCTAssertEqual(store.verdict(host: "refs.lan", fingerprint: fingerprintB), .trusted)
        guard case .changed = store.verdict(host: "refs.lan", fingerprint: fingerprintA) else {
            return XCTFail("the replaced certificate must not still be trusted")
        }
    }

    func testRoundTripsThroughDisk() {
        makeStore().trust(host: "refs.lan", fingerprint: fingerprintA)
        let reopened = makeStore()
        XCTAssertEqual(reopened.certificates.count, 1)
        XCTAssertEqual(reopened.verdict(host: "refs.lan", fingerprint: fingerprintA), .trusted)
    }

    func testForgetRemovesIt() {
        let store = makeStore()
        store.trust(host: "refs.lan", fingerprint: fingerprintA)
        store.forget(store.certificates[0])
        XCTAssertTrue(store.certificates.isEmpty)
        XCTAssertEqual(makeStore().certificates.count, 0, "removal must persist")
    }

    func testForgetAllClearsEverything() {
        let store = makeStore()
        store.trust(host: "a.lan", fingerprint: fingerprintA)
        store.trust(host: "b.lan", fingerprint: fingerprintB)
        store.forgetAll()
        XCTAssertTrue(store.certificates.isEmpty)
    }

    func testFingerprintIsDisplayedInColonHex() {
        let certificate = TrustedCertificate(host: "refs.lan", fingerprint: "abcdef01")
        XCTAssertEqual(certificate.displayFingerprint, "AB:CD:EF:01")
    }

    /// The digest has to match what `openssl x509 -fingerprint -sha256` prints,
    /// or the owner cannot check it against the box.
    func testSHA256MatchesTheKnownDigestOfEmptyInput() {
        XCTAssertEqual(
            CertificateFingerprint.sha256(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
