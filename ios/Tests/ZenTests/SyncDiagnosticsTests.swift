//  SyncDiagnosticsTests.swift
//  The transcript is the deliverable of #008AA — if it drops a step, or lets a
//  failure pass without raising it, the next "nothing happened" is as
//  undiagnosable as the first.

import XCTest

@testable import Zen

@MainActor
final class SyncDiagnosticsTests: XCTestCase {

    /// A fixed clock, so the transcript's timestamps are assertable.
    private func fixedClock(from start: Date = Date(timeIntervalSince1970: 1_757_900_000))
        -> (SyncDiagnostics, () -> Void)
    {
        let tick = TickingClock(start: start)
        return (SyncDiagnostics(now: { tick.now }), { tick.advance(1) })
    }

    private final class TickingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(start: Date) { value = start }
        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock()
            value = value.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    func testStepsAreRecordedInOrderWithTheirOutcome() {
        let (diagnostics, tick) = fixedClock()
        diagnostics.succeeded(.authorizeOpened, "context=oauth_webchannel_v1")
        tick()
        diagnostics.succeeded(.pageLoaded, "accounts.firefox.com")
        tick()
        diagnostics.succeeded(.fxaStatus, "answered")

        XCTAssertEqual(diagnostics.entries.map(\.step), [.authorizeOpened, .pageLoaded, .fxaStatus])
        XCTAssertEqual(diagnostics.entries.map(\.outcome), [.ok, .ok, .ok])
        XCTAssertEqual(diagnostics.lastStep, .fxaStatus)
        XCTAssertFalse(diagnostics.hasFailure)
        XCTAssertNil(diagnostics.failure)
        // Oldest first, and the clock moved between them.
        XCTAssertLessThan(diagnostics.entries[0].at, diagnostics.entries[2].at)
    }

    /// The whole point: a failure has to be *visible*, not merely logged.
    func testAFailureIsBothLoggedAndRaised() {
        let (diagnostics, _) = fixedClock()
        diagnostics.succeeded(.oauthLogin, "code: 64 chars")
        diagnostics.failed(.codeExchange, SyncError.server(status: 400, message: "invalid code"))

        XCTAssertTrue(diagnostics.hasFailure)
        XCTAssertEqual(diagnostics.entries.last?.outcome, .failed)
        XCTAssertEqual(diagnostics.failure?.step, .codeExchange)
        XCTAssertEqual(diagnostics.failure?.message, "invalid code (400)")
    }

    /// This is the exact scenario the simulator check drives: a synthetic
    /// `oauth_login` reaches the exchange, Mozilla rejects the fake code, and
    /// the rejection has to be the last line rather than a silence.
    func testARejectedCodeExchangeIsTheLastLine() {
        let (diagnostics, _) = fixedClock()
        diagnostics.succeeded(.pageLoaded, "accounts.firefox.com")
        diagnostics.succeeded(.fxaStatus, "answered")
        diagnostics.succeeded(.oauthLogin, "code: 8 chars")
        diagnostics.failed(
            .codeExchange, SyncError.server(status: 400, message: "Invalid authorization code"))

        XCTAssertEqual(diagnostics.lastStep, .codeExchange)
        XCTAssertTrue(diagnostics.transcript.contains("Invalid authorization code"))
        XCTAssertTrue(diagnostics.transcript.contains("✗ Code exchange"))
    }

    /// A deep failure is reported where it happened and summarised by its
    /// caller. One problem, one line, one alert.
    func testTheSameFailureIsNotRecordedTwice() {
        let (diagnostics, _) = fixedClock()
        diagnostics.failed(.tokenServer, SyncError.authenticationExpired)
        diagnostics.failed(.firstSync, SyncError.authenticationExpired)

        XCTAssertEqual(diagnostics.entries.count, 1)
        XCTAssertEqual(diagnostics.entries.first?.step, .tokenServer)
    }

    func testADifferentFailureStillLands() {
        let (diagnostics, _) = fixedClock()
        diagnostics.failed(.tokenServer, SyncError.authenticationExpired)
        diagnostics.failed(.firstSync, SyncError.scopedKeyMissing)
        XCTAssertEqual(diagnostics.entries.count, 2)
    }

    /// `localizedDescription` on a plain `NSError` is often useless on its own,
    /// so the domain and code ride along — that is what identifies a WebKit or
    /// URLSession failure on a ticket.
    func testANonSyncErrorKeepsItsDomainAndCode() throws {
        let (diagnostics, _) = fixedClock()
        diagnostics.failed(
            .pageLoaded,
            NSError(domain: NSURLErrorDomain, code: -1009, userInfo: nil))
        let message = try XCTUnwrap(diagnostics.failure?.message)
        XCTAssertTrue(message.contains(NSURLErrorDomain))
        XCTAssertTrue(message.contains("-1009"))
    }

    func testTheTranscriptIsTimestampedAndMarked() {
        let (diagnostics, tick) = fixedClock()
        diagnostics.log(.authorizeOpened, "starting")
        tick()
        diagnostics.succeeded(.pageLoaded)
        tick()
        diagnostics.failed(.codeExchange, message: "boom")

        let lines = diagnostics.transcript.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("2025-09-15T"))
        XCTAssertTrue(lines[0].contains("· Authorization opened — starting"))
        // No detail, no dash.
        XCTAssertTrue(lines[1].hasSuffix("✓ Sign-in page loaded"))
        XCTAssertTrue(lines[2].contains("✗ Code exchange — boom"))
    }

    /// A new attempt starts a new transcript: reading the previous run's
    /// success and thinking it is this one's is worse than no log at all.
    func testBeginningAnAttemptClearsTheLast() {
        let (diagnostics, _) = fixedClock()
        diagnostics.failed(.codeExchange, message: "boom")
        diagnostics.beginAttempt()
        XCTAssertTrue(diagnostics.entries.isEmpty)
        XCTAssertNil(diagnostics.failure)
        XCTAssertFalse(diagnostics.hasFailure)
    }

    func testTheLogIsBounded() {
        let (diagnostics, _) = fixedClock()
        for index in 0..<(SyncDiagnostics.capacity + 50) {
            diagnostics.log(.webChannel, "line \(index)")
        }
        XCTAssertEqual(diagnostics.entries.count, SyncDiagnostics.capacity)
        // The oldest went, not the newest.
        XCTAssertEqual(diagnostics.entries.last?.detail, "line \(SyncDiagnostics.capacity + 49)")
    }

    /// Codes and tokens are bearer credentials. The transcript records that
    /// one arrived and how long it was, never what it said.
    func testSecretsAreRecordedByShapeOnly() {
        let secret = "aaaaaaaabbbbbbbbccccccccdddddddd"
        let line = SyncDiagnostics.shape(secret, label: "code")
        XCTAssertEqual(line, "code: 32 chars")
        XCTAssertFalse(line.contains(secret))
        XCTAssertEqual(SyncDiagnostics.shape(nil, label: "refresh token"), "refresh token: missing")
        XCTAssertEqual(SyncDiagnostics.shape("", label: "code"), "code: missing")
    }
}
