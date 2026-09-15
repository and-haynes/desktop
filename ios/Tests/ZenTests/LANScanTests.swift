//  LANScanTests.swift
//  The parts of the scan that are decisions rather than sockets: how a subnet
//  becomes a list of addresses, what a port is taken to be, and what happens to
//  a finding once it is imported.
//
//  The sockets themselves are verified against a real network from the
//  simulator — see the note in the README — because a unit test of "does
//  10.0.0.42 answer on 8006" is a unit test of the wiring in the house.

import XCTest

@testable import Zen

final class LANScanTests: XCTestCase {

    // MARK: Subnet enumeration

    func testASlashTwentyFourEnumeratesItsUsableHosts() throws {
        let subnet = try XCTUnwrap(IPv4Subnet(address: "10.0.0.45", netmask: "255.255.255.0"))
        XCTAssertEqual(subnet.effectivePrefixLength, 24)
        XCTAssertEqual(subnet.displayCIDR, "10.0.0.0/24")
        let hosts = subnet.hostAddresses
        XCTAssertEqual(hosts.count, 254)
        XCTAssertEqual(hosts.first, "10.0.0.1")
        XCTAssertEqual(hosts.last, "10.0.0.254")
        XCTAssertFalse(hosts.contains("10.0.0.0"), "the network address is not a host")
        XCTAssertFalse(hosts.contains("10.0.0.255"), "the broadcast address is not a host")
        XCTAssertEqual(subnet.hostCount, hosts.count)
    }

    func testASlashTwentyFiveHalvesTheRange() throws {
        let subnet = try XCTUnwrap(IPv4Subnet(address: "192.168.1.200", netmask: "255.255.255.128"))
        XCTAssertEqual(subnet.effectivePrefixLength, 25)
        XCTAssertEqual(subnet.displayCIDR, "192.168.1.128/25")
        XCTAssertEqual(subnet.hostAddresses.first, "192.168.1.129")
        XCTAssertEqual(subnet.hostAddresses.last, "192.168.1.254")
        XCTAssertEqual(subnet.hostAddresses.count, 126)
    }

    /// The /22 cap. A misconfigured /8 is 16 million addresses, which is not a
    /// long scan — it is a hung app.
    func testAnythingWiderThanASlashTwentyTwoIsClamped() throws {
        let subnet = try XCTUnwrap(IPv4Subnet(address: "10.4.5.6", netmask: "255.0.0.0"))
        XCTAssertEqual(subnet.prefixLength, 8)
        XCTAssertEqual(subnet.effectivePrefixLength, IPv4Subnet.maxPrefixLength)
        XCTAssertTrue(subnet.wasClamped)
        XCTAssertEqual(subnet.hostAddresses.count, 1022)
        XCTAssertEqual(subnet.displayCIDR, "10.4.4.0/22")
    }

    /// Wider than a /24 is worth a warning even when it is not clamped.
    func testASlashTwentyThreeIsWarnedAboutButNotClamped() throws {
        let subnet = try XCTUnwrap(IPv4Subnet(address: "10.0.2.9", netmask: "255.255.254.0"))
        XCTAssertFalse(subnet.wasClamped)
        XCTAssertTrue(subnet.isWiderThanComfortable)
        XCTAssertEqual(subnet.hostAddresses.count, 510)
    }

    func testASlashTwentyFourIsNotWarnedAbout() throws {
        let subnet = try XCTUnwrap(IPv4Subnet(address: "10.0.0.45", netmask: "255.255.255.0"))
        XCTAssertFalse(subnet.isWiderThanComfortable)
    }

    func testASingleAddressSubnetEnumeratesItself() throws {
        let subnet = try XCTUnwrap(IPv4Subnet(address: "10.0.0.7", netmask: "255.255.255.255"))
        XCTAssertEqual(subnet.hostAddresses, ["10.0.0.7"])
    }

    func testRubbishAddressesDoNotParse() {
        XCTAssertNil(IPv4Subnet(address: "10.0.0", netmask: "255.255.255.0"))
        XCTAssertNil(IPv4Subnet(address: "10.0.0.999", netmask: "255.255.255.0"))
        XCTAssertNil(IPv4Subnet(address: "ten.oh.oh.one", netmask: "255.255.255.0"))
        XCTAssertNil(IPv4Subnet(address: "10.0.0.1", netmask: "nonsense"))
    }

    func testAddressesRoundTripThroughTheirPackedForm() {
        for address in ["0.0.0.0", "10.0.0.42", "192.168.1.255", "255.255.255.255"] {
            let packed = IPv4Subnet.parse(address)
            XCTAssertEqual(packed.map(IPv4Subnet.string), address)
        }
    }

    // MARK: Port → service

    func testTheHomelabPortsAreNamed() {
        XCTAssertEqual(LANPortCatalog.kind(for: 8006).name, "Proxmox")
        XCTAssertEqual(LANPortCatalog.kind(for: 8123).name, "Home Assistant")
        XCTAssertEqual(LANPortCatalog.kind(for: 8096).name, "Jellyfin")
        XCTAssertEqual(LANPortCatalog.kind(for: 32400).name, "Plex")
        XCTAssertEqual(LANPortCatalog.kind(for: 22).name, "SSH")
    }

    /// Proxmox is HTTPS on 8006 and Home Assistant is plain HTTP on 8123;
    /// getting either backwards means the import opens a URL that cannot load.
    func testTLSPortsAreHTTPSAndTheRestAreNot() {
        XCTAssertEqual(LANPortCatalog.scheme(for: 8006), "https")
        XCTAssertEqual(LANPortCatalog.scheme(for: 443), "https")
        XCTAssertEqual(LANPortCatalog.scheme(for: 8443), "https")
        XCTAssertEqual(LANPortCatalog.scheme(for: 9443), "https")
        XCTAssertEqual(LANPortCatalog.scheme(for: 8123), "http")
        XCTAssertEqual(LANPortCatalog.scheme(for: 80), "http")
    }

    func testNonWebPortsHaveNoScheme() {
        for port in [22, 2222, 445, 1883, 3389, 5432, 5900] {
            XCTAssertNil(LANPortCatalog.scheme(for: port), "port \(port) is not a web service")
            XCTAssertFalse(LANPortCatalog.kind(for: port).isWeb)
        }
    }

    /// Something answering on an unrecognised port is still most likely HTTP on
    /// a home network, so it is offered — but nothing is assumed about TLS.
    func testAnUnknownPortIsOfferedAsPlainHTTP() {
        let kind = LANPortCatalog.kind(for: 7860)
        XCTAssertEqual(kind.scheme, "http")
        XCTAssertEqual(kind.name, "Port 7860")
    }

    func testTheDefaultPortListIsSortedAndComplete() {
        XCTAssertEqual(LANPortCatalog.defaultPorts, LANPortCatalog.defaultPorts.sorted())
        for port in [22, 80, 443, 3000, 5000, 5432, 8000, 8006, 8080, 8096, 8123, 8443, 9000,
            9090, 32400, 1883, 5900, 3389, 445, 631, 8384, 9443, 2222]
        {
            XCTAssertTrue(LANPortCatalog.defaultPorts.contains(port), "port \(port) is missing")
        }
    }

    func testDefaultPortsLoseTheirPortNumberInTheURL() {
        let http = LANDiscoveredPort(port: 80).url(host: "10.0.0.42")
        XCTAssertEqual(http?.absoluteString, "http://10.0.0.42")
        let https = LANDiscoveredPort(port: 443).url(host: "10.0.0.42")
        XCTAssertEqual(https?.absoluteString, "https://10.0.0.42")
        let proxmox = LANDiscoveredPort(port: 8006).url(host: "10.0.0.80")
        XCTAssertEqual(proxmox?.absoluteString, "https://10.0.0.80:8006")
        XCTAssertNil(LANDiscoveredPort(port: 22).url(host: "10.0.0.42"))
    }

    // MARK: Scan configuration

    func testCustomPortsAreFoldedInWithoutDuplicates() {
        let subnet = IPv4Subnet(address: 0x0A00_0001, prefixLength: 24)
        let configuration = LANScanConfiguration(
            subnet: subnet, customPorts: [11434, 8006, 7860])
        let ports = configuration.ports
        XCTAssertEqual(ports, ports.sorted())
        XCTAssertEqual(Set(ports).count, ports.count)
        XCTAssertTrue(ports.contains(11434))
        XCTAssertEqual(ports.filter { $0 == 8006 }.count, 1)
    }

    func testThePrivilegedSweepIsOptIn() {
        let subnet = IPv4Subnet(address: 0x0A00_0001, prefixLength: 24)
        var configuration = LANScanConfiguration(subnet: subnet)
        XCTAssertFalse(configuration.ports.contains(139))
        configuration.includePrivilegedRange = true
        XCTAssertTrue(configuration.ports.contains(139))
        XCTAssertTrue(configuration.ports.contains(1))
        XCTAssertTrue(configuration.ports.contains(1024))
    }

    func testTypedPortsAcceptCommasOrSpaces() {
        XCTAssertEqual(LocalNetworkView.parsePorts("8000, 9090 3000"), [8000, 9090, 3000])
        XCTAssertEqual(LocalNetworkView.parsePorts("  "), [])
        XCTAssertEqual(LocalNetworkView.parsePorts("70000, 0, 443"), [443])
        XCTAssertEqual(LocalNetworkView.parsePorts("not-a-port"), [])
    }

    // MARK: Aliases

    func testAPageTitleBecomesTheSuggestedAlias() {
        var host = LANDiscoveredHost(address: "10.0.0.42")
        host.hostname = "meitner.lan"
        var port = LANDiscoveredPort(port: 8096)
        port.pageTitle = "Jellyfin"
        XCTAssertEqual(LocalService.suggestedAlias(host: host, port: port), "Jellyfin")
    }

    func testWithoutATitleTheHostNameIsUsed() {
        var host = LANDiscoveredHost(address: "10.0.0.42")
        host.hostname = "meitner.lan."
        let port = LANDiscoveredPort(port: 8096)
        XCTAssertEqual(
            LocalService.suggestedAlias(host: host, port: port), "meitner.lan Jellyfin")
    }

    func testWithNeitherTheAddressAndServiceAreUsed() {
        let host = LANDiscoveredHost(address: "10.0.0.80")
        let port = LANDiscoveredPort(port: 8006)
        XCTAssertEqual(
            LocalService.suggestedAlias(host: host, port: port), "Proxmox on 10.0.0.80")
    }

    /// Some pages have essays for titles.
    func testALongTitleIsTrimmed() {
        var port = LANDiscoveredPort(port: 80)
        port.pageTitle = String(repeating: "a", count: 300)
        let alias = LocalService.suggestedAlias(
            host: LANDiscoveredHost(address: "10.0.0.1"), port: port)
        XCTAssertEqual(alias.count, 48)
    }

    // MARK: The HTML title scrape

    func testTheTitleIsPulledOutOfTheFirstChunkOfHTML() {
        let html = "<!doctype html><html><head><title>Proxmox VE</title></head><body>"
        XCTAssertEqual(LANHTTPProbe.title(in: Data(html.utf8)), "Proxmox VE")
    }

    func testTitleAttributesAndEntitiesAreHandled() {
        let html = #"<title lang="en">Bob &amp; Alice&#39;s   NAS</title>"#
        XCTAssertEqual(LANHTTPProbe.title(in: Data(html.utf8)), "Bob & Alice's NAS")
    }

    func testAPageWithNoTitleGivesNothing() {
        XCTAssertNil(LANHTTPProbe.title(in: Data("<html><body>hi</body></html>".utf8)))
        XCTAssertNil(LANHTTPProbe.title(in: Data("<title></title>".utf8)))
        XCTAssertNil(LANHTTPProbe.title(in: Data()))
    }

    // MARK: Certificate validity

    /// The DER walk that replaces `SecCertificateCopyValues`, which iOS does
    /// not have. The dates themselves are the easy half to get wrong.
    func testUTCTimeYearsFollowRFC5280() throws {
        let twenties = try XCTUnwrap(X509Validity.date(from: "260915120000Z", generalized: false))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(calendar.component(.year, from: twenties), 2026)

        let nineties = try XCTUnwrap(X509Validity.date(from: "980915120000Z", generalized: false))
        XCTAssertEqual(calendar.component(.year, from: nineties), 1998)

        let general = try XCTUnwrap(
            X509Validity.date(from: "20991231235959Z", generalized: true))
        XCTAssertEqual(calendar.component(.year, from: general), 2099)
    }

    func testRubbishBytesProduceNoDate() {
        XCTAssertNil(X509Validity.notAfter(inDER: Data()))
        XCTAssertNil(X509Validity.notAfter(inDER: Data([0x30, 0x82, 0xFF, 0xFF])))
        XCTAssertNil(X509Validity.notAfter(inDER: Data(repeating: 0x41, count: 64)))
    }

    /// A real certificate, so the walk is tested against DER as it is actually
    /// emitted rather than against a hand-built fixture that happens to match
    /// the parser. Generated with:
    ///
    ///     openssl req -x509 -newkey rsa:2048 -keyout /dev/null -out cert.pem \
    ///       -days 3650 -nodes -subj "/CN=zen-test" \
    ///       -not_before 20250101000000Z -not_after 20350101000000Z
    func testARealCertificatesExpiryIsRead() throws {
        let der = try XCTUnwrap(Data(base64Encoded: Self.testCertificateDER))
        let expiry = try XCTUnwrap(X509Validity.notAfter(inDER: der))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(calendar.component(.year, from: expiry), Self.testCertificateExpiryYear)
    }

    // Filled in by `Tests/ZenTests/Fixtures` — see `LANScanFixtures.swift`.
    private static let testCertificateDER = LANScanFixtures.certificateDER
    private static let testCertificateExpiryYear = LANScanFixtures.certificateExpiryYear
}
