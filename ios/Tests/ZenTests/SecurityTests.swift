//  SecurityTests.swift
//  The trusted-certificate store and the failure classifier behind the calm
//  home-network prompt (#00889).
//
//  The LAN host classifier itself is tested in LANHostTests.swift — it is
//  shared with the error page's Local Network hint on the `ios` branch, so it
//  lives in its own file rather than here.

import XCTest

@testable import Zen

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
