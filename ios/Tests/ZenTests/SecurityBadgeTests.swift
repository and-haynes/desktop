//  SecurityBadgeTests.swift
//  The URL pill's glyph decides what tapping it opens, so the mapping is the
//  whole feature (#0089A). The precedence between "the load failed", "a
//  certificate prompt is waiting" and "this host is approved" is the part that
//  is easy to get subtly wrong and impossible to notice.

import XCTest

@testable import Zen

@MainActor
final class SecurityBadgeTests: XCTestCase {

    private var directory: URL!
    private var state: BrowserState!
    private var trusted: TrustedCertificateStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenBadge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        trusted = TrustedCertificateStore(
            file: JSONFileStore<[TrustedCertificate]>(name: "certs.json", directory: directory))
        state = BrowserState(
            session: SessionStore(
                file: JSONFileStore<SessionSnapshot>(name: "session.json", directory: directory)),
            history: HistoryStore(
                file: JSONFileStore<[HistoryEntry]>(name: "history.json", directory: directory)),
            trustedCertificates: trusted,
            restore: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func tab(_ urlString: String) -> Tab {
        Tab(url: URL(string: urlString)!, title: "T", kind: .normal, spaceID: state.activeSpaceID)
    }

    // MARK: The mapping

    func testTheStartPageSaysNothing() {
        var newTab = tab("https://example.com")
        newTab.url = Tab.newTab(in: UUID()).url
        XCTAssertEqual(state.securityBadge(for: newTab), .search)
        XCTAssertFalse(SecurityBadge.search.isActionable)
    }

    func testOrdinaryHTTPSIsSecureAndNotActionable() {
        XCTAssertEqual(state.securityBadge(for: tab("https://example.com/x")), .secure)
        XCTAssertFalse(SecurityBadge.secure.isActionable)
        XCTAssertFalse(SecurityBadge.secure.isWarning)
    }

    func testPlainHTTPIsInsecureAndActionable() {
        XCTAssertEqual(state.securityBadge(for: tab("http://meitner:8006/")), .insecure)
        XCTAssertTrue(SecurityBadge.insecure.isActionable)
        XCTAssertTrue(SecurityBadge.insecure.isWarning)
    }

    func testAnApprovedCertificateShowsAsTrusted() {
        trusted.trust(host: "meitner", fingerprint: "abcd")
        guard case .trusted(let certificate) = state.securityBadge(for: tab("https://meitner:8006/"))
        else { return XCTFail("an approved host should report as trusted") }
        XCTAssertEqual(certificate.host, "meitner")
        XCTAssertTrue(SecurityBadge.trusted(certificate).isActionable)
        // Approved is not a warning: you already answered this question.
        XCTAssertFalse(SecurityBadge.trusted(certificate).isWarning)
    }

    func testApprovalIsMatchedCaseInsensitivelyOnTheHost() {
        trusted.trust(host: "Meitner", fingerprint: "abcd")
        guard case .trusted = state.securityBadge(for: tab("https://MEITNER/")) else {
            return XCTFail("host matching should ignore case")
        }
    }

    func testAnApprovedHostDoesNotBleedOntoOtherHosts() {
        trusted.trust(host: "meitner", fingerprint: "abcd")
        XCTAssertEqual(state.securityBadge(for: tab("https://noether/")), .secure)
    }

    /// A pending prompt outranks "secure": the page is blocked on a question.
    func testAWaitingChallengeOutranksTheLock() {
        let challenge = PendingCertificateChallenge(
            host: "meitner", fingerprint: "ab", failure: .selfSigned, isLocalNetwork: true,
            previousCertificate: nil, completion: { _ in })
        state.presentCertificateChallenge(challenge)
        XCTAssertEqual(state.securityBadge(for: tab("https://meitner:8006/")), .challenge)
        // …but only for the host it is about.
        XCTAssertEqual(state.securityBadge(for: tab("https://example.com/")), .secure)
        challenge.resolve(.reject)
    }

    /// A failed load outranks everything — whatever the scheme said, there is
    /// no page, and that is the more useful thing to explain.
    func testAFailedLoadOutranksEverything() {
        let challenge = PendingCertificateChallenge(
            host: "meitner", fingerprint: "ab", failure: .selfSigned, isLocalNetwork: true,
            previousCertificate: nil, completion: { _ in })
        state.presentCertificateChallenge(challenge)
        var failed = tab("https://meitner:8006/")
        failed.loadFailure = LoadFailure(
            url: failed.url, kind: .cannotConnect, code: NSURLErrorCannotConnectToHost,
            localizedDescription: "Could not connect to the server.")
        guard case .failed = state.securityBadge(for: failed) else {
            return XCTFail("a failed load should be reported as such")
        }
        challenge.resolve(.reject)
    }

    // MARK: What the tap opens

    func testTappingAnApprovedHostOpensItsRecord() {
        trusted.trust(host: "meitner", fingerprint: "abcd")
        state.openSecurityDetail(for: tab("https://meitner/"))
        guard case .trusted(let certificate)? = state.securityDetail else {
            return XCTFail("expected the certificate record")
        }
        XCTAssertEqual(certificate.host, "meitner")
    }

    func testTappingPlainHTTPOpensTheExplanation() {
        state.openSecurityDetail(for: tab("http://meitner:8006/"))
        XCTAssertEqual(state.securityDetail, .insecure(host: "meitner"))
    }

    func testTappingASecureLockOpensNothing() {
        state.openSecurityDetail(for: tab("https://example.com/"))
        XCTAssertNil(state.securityDetail)
    }

    /// Tapping the badge while a prompt is waiting must *clear* any detail
    /// sheet rather than open one — that is what un-gates the prompt.
    func testTappingAWaitingChallengeClearsTheWayForThePrompt() {
        state.securityDetail = .insecure(host: "somewhere")
        let challenge = PendingCertificateChallenge(
            host: "meitner", fingerprint: "ab", failure: .selfSigned, isLocalNetwork: true,
            previousCertificate: nil, completion: { _ in })
        state.presentCertificateChallenge(challenge)
        state.openSecurityDetail(for: tab("https://meitner/"))
        XCTAssertNil(state.securityDetail)
        XCTAssertNotNil(state.pendingCertificateChallenge)
        challenge.resolve(.reject)
    }

    // MARK: The queue

    func testAnyOtherSheetBlocksThePrompt() {
        XCTAssertFalse(state.isBlockingSheetPresented)
        state.isSettingsPresented = true
        XCTAssertTrue(state.isBlockingSheetPresented)
        state.isSettingsPresented = false
        state.isHistorySheetPresented = true
        XCTAssertTrue(state.isBlockingSheetPresented)
        state.isHistorySheetPresented = false
        state.securityDetail = .insecure(host: "meitner")
        XCTAssertTrue(state.isBlockingSheetPresented)
        state.securityDetail = nil
        XCTAssertFalse(state.isBlockingSheetPresented)
    }

    /// The challenge survives being covered — it is queued, not dropped.
    func testAChallengeRaisedBehindASheetIsKept() {
        state.isSettingsPresented = true
        var answered: PendingCertificateChallenge.Disposition?
        let challenge = PendingCertificateChallenge(
            host: "meitner", fingerprint: "ab", failure: .selfSigned, isLocalNetwork: true,
            previousCertificate: nil, completion: { answered = $0 })
        state.presentCertificateChallenge(challenge)
        XCTAssertNotNil(state.pendingCertificateChallenge)
        XCTAssertNil(answered, "it must not be auto-rejected just because a sheet was up")

        state.isSettingsPresented = false
        XCTAssertFalse(state.isBlockingSheetPresented)
        XCTAssertNotNil(state.pendingCertificateChallenge)
        state.resolveCertificateChallenge(.trust)
        XCTAssertEqual(answered, .trust)
    }
}
