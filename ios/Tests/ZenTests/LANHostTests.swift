//  LANHostTests.swift
//  Is this host on the home network? (#00889 / #0089A)
//
//  The classifier gates both the friendly certificate prompt and the error
//  page's Local Network hint. It may be wrong in exactly one direction —
//  missing a LAN host is annoying, calling a public host local is dangerous —
//  so the negative cases carry the weight here.

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
