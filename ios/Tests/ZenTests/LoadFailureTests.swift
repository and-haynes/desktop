//  LoadFailureTests.swift
//  The silent-failure bug (#0089A).
//
//  Reported from the phone: https://10.0.0.80 "never loads, nothing happens,
//  and a warning triangle appears that cannot be tapped". 10.0.0.80 is a
//  Proxmox host whose UI is on :8006 with nothing on :443, so the real events
//  are a refused connection and a browser with no way to say so.

import XCTest

@testable import Zen

final class LoadFailureTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func error(_ code: Int, url: URL) -> NSError {
        NSError(
            domain: NSURLErrorDomain, code: code,
            userInfo: [
                NSURLErrorFailingURLErrorKey: url,
                NSLocalizedDescriptionKey: "test failure",
            ])
    }

    // MARK: Classification

    func testRefusedConnectionIsCannotConnect() {
        let target = url("https://10.0.0.80")
        let failure = LoadFailure.classify(
            error(NSURLErrorCannotConnectToHost, url: target), url: target)
        XCTAssertEqual(failure?.kind, .cannotConnect)
        XCTAssertEqual(failure?.code, NSURLErrorCannotConnectToHost)
    }

    func testTimeoutIsTimedOut() {
        let target = url("https://10.255.255.1")
        XCTAssertEqual(
            LoadFailure.classify(error(NSURLErrorTimedOut, url: target), url: target)?.kind,
            .timedOut)
    }

    func testTLSFailuresAreGroupedAsSecure() {
        let target = url("https://refs.lan")
        for code in [
            NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
        ] {
            XCTAssertEqual(
                LoadFailure.classify(error(code, url: target), url: target)?.kind,
                .secureConnectionFailed, "code \(code)")
        }
    }

    func testMissingNetworkIsDistinguishedFromARefusal() {
        let target = url("https://10.0.0.80")
        XCTAssertEqual(
            LoadFailure.classify(error(NSURLErrorNotConnectedToInternet, url: target), url: target)?
                .kind, .noNetwork)
    }

    /// A cancelled load is a redirect or a second tap, not a failure — showing
    /// an error page for it would be worse than the bug.
    func testCancellationIsNotAFailure() {
        let target = url("https://example.com")
        XCTAssertNil(LoadFailure.classify(error(NSURLErrorCancelled, url: target), url: target))
    }

    func testUnknownCodesFallBackToOther() {
        let target = url("https://example.com")
        XCTAssertEqual(
            LoadFailure.classify(error(-99999, url: target), url: target)?.kind, .other)
    }

    // MARK: Ports

    func testDefaultPortIsInferredFromTheScheme() {
        let https = LoadFailure.timeoutFailure(url: url("https://10.0.0.80"))
        XCTAssertEqual(https.port, 443)
        XCTAssertTrue(https.usedDefaultPort)

        let http = LoadFailure.timeoutFailure(url: url("http://10.0.0.80"))
        XCTAssertEqual(http.port, 80)

        let explicit = LoadFailure.timeoutFailure(url: url("https://10.0.0.80:8006"))
        XCTAssertEqual(explicit.port, 8006)
        XCTAssertFalse(explicit.usedDefaultPort)
    }

    /// The reported case, end to end: the suggestions must include the port
    /// Proxmox actually uses.
    func testRefusedDefaultPortSuggestsCommonPortsIncluding8006() {
        let target = url("https://10.0.0.80")
        let failure = LoadFailure(
            url: target, kind: .cannotConnect, code: NSURLErrorCannotConnectToHost,
            localizedDescription: "refused")
        let suggested = failure.suggestions().map(\.url.absoluteString)
        XCTAssertTrue(
            suggested.contains("https://10.0.0.80:8006"), "missing Proxmox's port: \(suggested)")
        XCTAssertTrue(suggested.contains("http://10.0.0.80"), "missing the scheme flip")
    }

    /// Someone who named a port does not want a list of other ports.
    func testAnExplicitPortSuppressesThePortSuggestions() {
        let failure = LoadFailure(
            url: url("https://10.0.0.80:8006"), kind: .cannotConnect,
            code: NSURLErrorCannotConnectToHost, localizedDescription: "refused")
        let labels = failure.suggestions().map(\.label)
        XCTAssertFalse(labels.contains(":8080"))
        // The scheme flip is still worth offering.
        XCTAssertTrue(labels.contains("Try http://"))
    }

    func testSchemeFlipPreservesAnExplicitPort() {
        let failure = LoadFailure.timeoutFailure(url: url("https://10.0.0.80:8006"))
        let flipped = failure.suggestions().first { $0.label.contains("http://") }
        XCTAssertEqual(flipped?.url.absoluteString, "http://10.0.0.80:8006")
    }

    func testPortSuggestionsAreNotOfferedForDNSFailures() {
        let failure = LoadFailure(
            url: url("https://nope.example"), kind: .hostNotFound,
            code: NSURLErrorCannotFindHost, localizedDescription: "no host")
        XCTAssertFalse(failure.suggestions().contains { $0.label.hasPrefix(":") })
    }

    // MARK: Presentation

    func testLocalNetworkFailuresAreFlaggedForTheHint() {
        XCTAssertTrue(LoadFailure.timeoutFailure(url: url("https://10.0.0.80")).isLocalNetwork)
        XCTAssertTrue(LoadFailure.timeoutFailure(url: url("https://refs.lan")).isLocalNetwork)
        XCTAssertFalse(LoadFailure.timeoutFailure(url: url("https://example.com")).isLocalNetwork)
    }

    func testEveryKindHasATitleAndAMessageNamingTheHost() {
        let target = url("https://10.0.0.80")
        let kinds: [LoadFailure.Kind] = [
            .cannotConnect, .timedOut, .hostNotFound, .noNetwork, .secureConnectionFailed,
            .unsupportedScheme("mailto"), .other,
        ]
        for kind in kinds {
            let failure = LoadFailure(
                url: target, kind: kind, code: -1, localizedDescription: "details")
            XCTAssertFalse(failure.title.isEmpty, "\(kind) has no title")
            XCTAssertFalse(failure.message.isEmpty, "\(kind) has no message")
        }
    }

    /// Ten seconds, not WebKit's minute — a LAN host that is not there should
    /// say so before you give up on the app.
    func testTimeoutBudgetIsShort() {
        XCTAssertLessThanOrEqual(LoadFailure.timeout, 10)
        XCTAssertGreaterThan(LoadFailure.timeout, 2)
    }

    func testURLPortRewriteKeepsPathAndScheme() {
        XCTAssertEqual(
            url("https://10.0.0.80/admin").withPort(8006)?.absoluteString,
            "https://10.0.0.80:8006/admin")
    }
}

/// The other half of the report: input that must never be treated as a search.
final class LANAddressDetectionTests: XCTestCase {

    private func assertNavigates(
        _ input: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        switch URLDetector.intent(for: input, engine: .duckduckgo) {
        case .navigate:
            break
        case .search:
            XCTFail("\"\(input)\" was searched, not navigated", file: file, line: line)
        }
    }

    func testBareIPsAlwaysNavigate() {
        for input in ["10.0.0.80", "192.168.1.1", "172.16.0.1", "127.0.0.1", "10.255.255.1"] {
            assertNavigates(input)
        }
    }

    func testIPsWithPortsAlwaysNavigate() {
        for input in ["10.0.0.80:8006", "192.168.1.1:8080", "127.0.0.1:8443", "10.0.0.45:3000"] {
            assertNavigates(input)
        }
    }

    func testIPsWithSchemeAndPortNavigate() {
        for input in [
            "https://10.0.0.80:8006", "http://10.0.0.80", "https://10.0.0.80",
            "https://10.0.0.80:8006/", "http://192.168.1.1:8080/admin",
        ] {
            assertNavigates(input)
        }
    }

    /// A single-label name navigates when it carries something host-like — a
    /// port, a path, or an explicit scheme.
    func testSingleLabelHostsNavigateWhenTheyLookLikeHosts() {
        for input in [
            "meitner:8006", "meitner/", "noether/status", "http://meitner",
            "refs.lan", "refs.lan:8443",
        ] {
            assertNavigates(input)
        }
    }

    /// And a bare word stays a search: "meitner" and "swift" are the same
    /// string to a parser, and breaking every one-word search would cost far
    /// more than it saves. Typing a scheme, a port or a slash resolves it.
    func testABareSingleWordIsStillASearch() {
        for input in ["meitner", "noether", "swift", "zen"] {
            if case .navigate(let url) = URLDetector.intent(for: input, engine: .duckduckgo) {
                XCTFail("\"\(input)\" navigated to \(url); bare words must search")
            }
        }
    }

    /// A colon is not automatically a port — "ratio 3:2" is a search, and a
    /// nonsense port must not turn a phrase into a navigation.
    func testNonPortColonsAreStillSearched() {
        for input in ["ratio 3:2", "score 10:0", "note:todo"] {
            if case .navigate(let url) = URLDetector.intent(for: input, engine: .duckduckgo) {
                XCTFail("\"\(input)\" navigated to \(url)")
            }
        }
    }

    func testOutOfRangePortIsNotANavigation() {
        if case .navigate = URLDetector.intent(for: "10.0.0.80:99999", engine: .duckduckgo) {
            XCTFail("an invalid port should not navigate")
        }
    }
}
