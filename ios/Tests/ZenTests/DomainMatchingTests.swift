//  DomainMatchingTests.swift
//  Which logins a page is allowed to see (#008AD).
//
//  This is the security-critical half of the feature, so the tests are written
//  from the attacker's side as much as the user's: the cases that must *not*
//  match get as much room as the ones that must. A password manager that is
//  merely inconvenient is a bug; one that offers your bank login to
//  `bank.com.evil.net` is an incident.

import XCTest

@testable import Zen

final class DomainMatchingTests: XCTestCase {

    // MARK: Registrable domain

    func testOrdinaryDomains() {
        XCTAssertEqual(DomainMatching.registrableDomain(ofHost: "example.com"), "example.com")
        XCTAssertEqual(DomainMatching.registrableDomain(ofHost: "www.example.com"), "example.com")
        XCTAssertEqual(
            DomainMatching.registrableDomain(ofHost: "accounts.google.com"), "google.com")
        XCTAssertEqual(
            DomainMatching.registrableDomain(ofHost: "a.b.c.d.example.com"), "example.com")
    }

    func testMultiLabelPublicSuffixes() {
        XCTAssertEqual(DomainMatching.registrableDomain(ofHost: "bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(DomainMatching.registrableDomain(ofHost: "www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(
            DomainMatching.registrableDomain(ofHost: "shop.example.com.au"), "example.com.au")
    }

    /// The whole point of the public suffix list: two registrations under one
    /// suffix are two different owners, and `co.uk` itself has no owner.
    func testAPublicSuffixAloneHasNoRegistrableDomain() {
        XCTAssertNil(DomainMatching.registrableDomain(ofHost: "co.uk"))
        XCTAssertNil(DomainMatching.registrableDomain(ofHost: "github.io"))
    }

    /// Two GitHub Pages sites belong to two different people.
    func testPrivateSuffixesSeparateTheirTenants() {
        XCTAssertEqual(DomainMatching.registrableDomain(ofHost: "andy.github.io"), "andy.github.io")
        XCTAssertNotEqual(
            DomainMatching.registrableDomain(ofHost: "andy.github.io"),
            DomainMatching.registrableDomain(ofHost: "someone-else.github.io"))
    }

    /// An IP address and a single-label host have no registrable domain, and
    /// that is deliberate — grouping `10.0.0.41` with `10.0.0.42` under a
    /// "domain" would hand the homelab's logins to each other.
    func testHostsWithNoRegistrableDomain() {
        XCTAssertNil(DomainMatching.registrableDomain(ofHost: "10.0.0.41"))
        XCTAssertNil(DomainMatching.registrableDomain(ofHost: "127.0.0.1"))
        XCTAssertNil(DomainMatching.registrableDomain(ofHost: "::1"))
        XCTAssertNil(DomainMatching.registrableDomain(ofHost: "localhost"))
        XCTAssertNil(DomainMatching.registrableDomain(ofHost: "vault"))
    }

    /// The homelab's own names are two labels and behave normally.
    func testHomelabNames() {
        XCTAssertEqual(DomainMatching.registrableDomain(ofHost: "vault.lan"), "vault.lan")
        XCTAssertEqual(DomainMatching.registrableDomain(ofHost: "tickets.lan"), "tickets.lan")
        XCTAssertNotEqual(
            DomainMatching.registrableDomain(ofHost: "vault.lan"),
            DomainMatching.registrableDomain(ofHost: "tickets.lan"))
    }

    func testHostNormalisation() {
        XCTAssertEqual(DomainMatching.normaliseHost("EXAMPLE.com"), "example.com")
        XCTAssertEqual(DomainMatching.normaliseHost("example.com."), "example.com")
        XCTAssertEqual(DomainMatching.normaliseHost("[::1]"), "::1")
        XCTAssertEqual(DomainMatching.normaliseHost("  example.com  "), "example.com")
    }

    // MARK: Pulling a host out of what vaults actually store

    func testHostExtractionToleratesVaultURIShapes() {
        let expectations = [
            "https://example.com/login": "example.com",
            "http://example.com": "example.com",
            // No scheme: `URL` would call this a path, not a host.
            "example.com": "example.com",
            "example.com/login": "example.com",
            "*.example.com": "example.com",
            "https://example.com:8443/": "example.com",
            "https://user@example.com/": "example.com",
        ]
        for (input, expected) in expectations {
            XCTAssertEqual(
                DomainMatching.host(ofURLString: input), expected, "extracting host from \(input)")
        }
    }

    // MARK: Matching

    private func login(_ uris: [VaultURI], title: String = "Example") -> VaultLogin {
        VaultLogin(id: VaultItemID(title), title: title, username: "andy", uris: uris)
    }

    func testDomainMatchIsTheDefaultAndSpansSubdomains() {
        let stored = VaultURI(uri: "https://google.com", match: .domain)
        let page = URL(string: "https://accounts.google.com/signin")!
        XCTAssertEqual(DomainMatching.quality(of: stored, against: page), .domain)
    }

    /// An exact host match outranks a mere same-domain one, because the panel
    /// sorts on it and the first row is the one people tap.
    func testExactHostOutranksSameDomain() {
        let page = URL(string: "https://accounts.google.com/signin")!
        let exact = VaultURI(uri: "https://accounts.google.com", match: .domain)
        let broad = VaultURI(uri: "https://google.com", match: .domain)
        XCTAssertGreaterThan(
            DomainMatching.quality(of: exact, against: page),
            DomainMatching.quality(of: broad, against: page))
    }

    /// The attack this file exists to prevent.
    func testASuffixLookalikeDoesNotMatch() {
        let stored = VaultURI(uri: "https://bank.com", match: .domain)
        for hostile in [
            "https://bank.com.evil.net/login",
            "https://evil.net/?next=bank.com",
            "https://notbank.com/login",
            "https://bank.com.br/login",
            "https://bank.co.uk/login",
        ] {
            XCTAssertEqual(
                DomainMatching.quality(of: stored, against: URL(string: hostile)!), .none,
                "\(hostile) must not match a login stored for bank.com")
        }
    }

    /// Different registrations under one public suffix are different sites.
    func testDifferentCountryRegistrationsDoNotMatchEachOther() {
        let stored = VaultURI(uri: "https://example.co.uk", match: .domain)
        XCTAssertEqual(
            DomainMatching.quality(
                of: stored, against: URL(string: "https://example.com")!), .none)
    }

    func testHostMatchIgnoresSubdomains() {
        let stored = VaultURI(uri: "https://vault.lan", match: .host)
        XCTAssertEqual(
            DomainMatching.quality(of: stored, against: URL(string: "https://vault.lan/#/login")!),
            .host)
        XCTAssertEqual(
            DomainMatching.quality(
                of: stored, against: URL(string: "https://admin.vault.lan/")!), .none)
    }

    /// Two services on one homelab host, told apart by port.
    func testHostMatchRespectsThePort() {
        let stored = VaultURI(uri: "https://pi-a.lan:8443", match: .host)
        XCTAssertEqual(
            DomainMatching.quality(
                of: stored, against: URL(string: "https://pi-a.lan:8443/app")!), .host)
        XCTAssertEqual(
            DomainMatching.quality(
                of: stored, against: URL(string: "https://pi-a.lan:9000/app")!), .none)
    }

    /// An IP-addressed login matches that IP and nothing else on the subnet.
    func testIPAddressesMatchExactlyOrNotAtAll() {
        let stored = VaultURI(uri: "https://10.0.0.41:8200", match: .domain)
        XCTAssertEqual(
            DomainMatching.quality(
                of: stored, against: URL(string: "https://10.0.0.41:8200/mcp")!), .host)
        XCTAssertEqual(
            DomainMatching.quality(
                of: stored, against: URL(string: "https://10.0.0.42:8200/mcp")!), .none)
    }

    func testExactAndStartsWith() {
        let exact = VaultURI(uri: "https://example.com/a", match: .exact)
        XCTAssertEqual(
            DomainMatching.quality(of: exact, against: URL(string: "https://example.com/a")!),
            .exact)
        XCTAssertEqual(
            DomainMatching.quality(of: exact, against: URL(string: "https://example.com/ab")!),
            .none)

        let prefix = VaultURI(uri: "https://example.com/app", match: .startsWith)
        XCTAssertEqual(
            DomainMatching.quality(
                of: prefix, against: URL(string: "https://example.com/app/login")!), .exact)
        XCTAssertEqual(
            DomainMatching.quality(
                of: prefix, against: URL(string: "https://example.com/other")!), .none)
    }

    /// An unanchored pattern matching a substring is how a hostile URL steals
    /// a login, so patterns are anchored at both ends.
    func testRegularExpressionsAreAnchored() {
        let stored = VaultURI(uri: "https://example\\.com/.*", match: .regularExpression)
        XCTAssertEqual(
            DomainMatching.quality(
                of: stored, against: URL(string: "https://example.com/login")!), .exact)
        XCTAssertEqual(
            DomainMatching.quality(
                of: stored, against: URL(string: "https://evil.net/?x=https://example.com/a")!),
            .none)
    }

    /// `never` is a user saying "do not offer this here", and it is obeyed.
    func testNeverNeverMatches() {
        let stored = VaultURI(uri: "https://example.com", match: .never)
        XCTAssertEqual(
            DomainMatching.quality(of: stored, against: URL(string: "https://example.com/")!),
            .none)
    }

    // MARK: Ordering

    func testMatchesAreSortedBestFirstThenByTitle() {
        let page = URL(string: "https://accounts.google.com/signin")!
        let logins = [
            login([VaultURI(uri: "https://google.com")], title: "Zed broad"),
            login([VaultURI(uri: "https://accounts.google.com")], title: "Bea exact"),
            login([VaultURI(uri: "https://google.com")], title: "Ann broad"),
            login([VaultURI(uri: "https://example.com")], title: "Not a match"),
        ]
        let matches = DomainMatching.matches(for: page, in: logins)
        XCTAssertEqual(matches.map(\.title), ["Bea exact", "Ann broad", "Zed broad"])
    }

    /// A login with several URIs is ranked by its best one.
    func testALoginIsRankedByItsBestURI() {
        let page = URL(string: "https://accounts.google.com/signin")!
        let multi = login([
            VaultURI(uri: "https://example.com"),
            VaultURI(uri: "https://accounts.google.com"),
        ])
        XCTAssertEqual(DomainMatching.quality(of: multi, against: page), .host)
    }

    func testALoginWithNoURIsMatchesNothing() {
        XCTAssertEqual(
            DomainMatching.quality(
                of: login([]), against: URL(string: "https://example.com/")!), .none)
    }
}
