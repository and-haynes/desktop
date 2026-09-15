//  LocalServiceStoreTests.swift
//  What happens to a finding once it stops being a finding.
//
//  Two rules carry most of the weight here: identity is the URL, not the alias
//  (so renaming does not fork the record and re-importing does not duplicate
//  it), and a certificate that *changed* is flagged rather than quietly
//  overwritten — the same line #00889 draws from the other direction.

import XCTest

@testable import Zen

@MainActor
final class LocalServiceStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenLocal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(named name: String = "local.json") -> LocalServiceStore {
        LocalServiceStore(file: JSONFileStore(url: directory.appendingPathComponent(name)))
    }

    private func service(
        _ alias: String, _ host: String = "10.0.0.80", port: Int = 8006,
        fingerprint: String? = nil
    ) -> LocalService {
        let scheme = LANPortCatalog.scheme(for: port) ?? "http"
        let url = URL(string: "\(scheme)://\(host):\(port)")!
        return LocalService(
            alias: alias, host: host, hostname: nil, port: port, url: url,
            certificate: fingerprint.map {
                LANCertificateInfo(fingerprint: $0, subject: "CN=\(host)", expires: nil)
            })
    }

    // MARK: Import

    func testImportingKeepsAService() {
        let store = makeStore()
        store.importService(service("Proxmox"))
        XCTAssertEqual(store.services.count, 1)
        XCTAssertEqual(store.services.first?.alias, "Proxmox")
        XCTAssertEqual(store.services.first?.port, 8006)
    }

    /// Identity is the URL. Importing the same address twice must update the
    /// record, not stack a second one beside it.
    func testImportingTheSameAddressTwiceUpdatesRatherThanDuplicates() {
        let store = makeStore()
        store.importService(service("Proxmox"))
        let before = store.services.first?.lastSeen
        store.importService(service("pve"))
        XCTAssertEqual(store.services.count, 1)
        XCTAssertNotNil(before)
        XCTAssertGreaterThanOrEqual(
            store.services.first?.lastSeen ?? .distantPast, before ?? .distantFuture)
    }

    func testRenamingSurvivesAReload() {
        let store = makeStore()
        store.importService(service("Proxmox"))
        let kept = try? XCTUnwrap(store.services.first)
        guard let kept else { return XCTFail("nothing imported") }
        store.rename(kept, to: "pve")
        store.setNotes(kept, "the hypervisor")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.services.count, 1)
        XCTAssertEqual(reloaded.services.first?.alias, "pve")
        XCTAssertEqual(reloaded.services.first?.notes, "the hypervisor")
        XCTAssertEqual(reloaded.services.first?.url, kept.url)
    }

    func testAnEmptyAliasIsRefused() {
        let store = makeStore()
        store.importService(service("Proxmox"))
        guard let kept = store.services.first else { return XCTFail("nothing imported") }
        store.rename(kept, to: "   ")
        XCTAssertEqual(store.services.first?.alias, "Proxmox")
    }

    func testForgettingRemovesIt() {
        let store = makeStore()
        store.importService(service("Proxmox"))
        store.importService(service("Jellyfin", "10.0.0.42", port: 8096))
        guard let first = store.services.first else { return XCTFail("nothing imported") }
        store.forget(first)
        XCTAssertEqual(store.services.count, 1)
        store.forgetAll()
        XCTAssertTrue(store.isEmpty)
        XCTAssertTrue(makeStore().isEmpty, "forgetting must reach the file")
    }

    // MARK: Certificates

    func testAChangedCertificateIsFlaggedRatherThanSwallowed() {
        let store = makeStore()
        store.importService(service("Proxmox", fingerprint: "aaaa"))
        XCTAssertNil(store.services.first?.certificateChangedAt)

        store.importService(service("Proxmox", fingerprint: "bbbb"))
        XCTAssertNotNil(store.services.first?.certificateChangedAt)
        XCTAssertEqual(store.services.first?.certificate?.fingerprint, "bbbb")

        guard let kept = store.services.first else { return XCTFail("nothing imported") }
        store.acknowledgeCertificate(kept)
        XCTAssertNil(store.services.first?.certificateChangedAt)
    }

    func testTheSameCertificateIsNotAChange() {
        let store = makeStore()
        store.importService(service("Proxmox", fingerprint: "aaaa"))
        store.importService(service("Proxmox", fingerprint: "aaaa"))
        XCTAssertNil(store.services.first?.certificateChangedAt)
    }

    // MARK: Re-scan merge

    func testARescanRefreshesWhatIsKeptAndAddsNothing() {
        let store = makeStore()
        store.importService(service("Proxmox", fingerprint: "aaaa"))
        let before = store.services.first?.lastSeen ?? .distantPast

        var host = LANDiscoveredHost(address: "10.0.0.80")
        host.ports = [
            LANDiscoveredPort(
                port: 8006, pageTitle: "Proxmox VE",
                certificate: LANCertificateInfo(
                    fingerprint: "aaaa", subject: "CN=pve", expires: nil)),
            // Something new on the same host; a refresh must not import it.
            LANDiscoveredPort(port: 9090),
        ]
        var other = LANDiscoveredHost(address: "10.0.0.42")
        other.ports = [LANDiscoveredPort(port: 8096)]

        store.refresh(from: [host, other])
        XCTAssertEqual(store.services.count, 1, "a re-scan updates, it does not import")
        XCTAssertGreaterThanOrEqual(store.services.first?.lastSeen ?? .distantPast, before)
        XCTAssertNil(store.services.first?.certificateChangedAt)
    }

    func testARescanFlagsAChangedCertificate() {
        let store = makeStore()
        store.importService(service("Proxmox", fingerprint: "aaaa"))
        var host = LANDiscoveredHost(address: "10.0.0.80")
        host.ports = [
            LANDiscoveredPort(
                port: 8006, pageTitle: nil,
                certificate: LANCertificateInfo(
                    fingerprint: "cccc", subject: "CN=pve", expires: nil))
        ]
        store.refresh(from: [host])
        XCTAssertNotNil(store.services.first?.certificateChangedAt)
    }

    // MARK: Grouping and search

    func testServicesGroupByHost() {
        let store = makeStore()
        store.importService(service("Proxmox", "10.0.0.80", port: 8006))
        store.importService(service("PVE web", "10.0.0.80", port: 8080))
        store.importService(service("Jellyfin", "10.0.0.42", port: 8096))
        let groups = store.byHost
        XCTAssertEqual(groups.count, 2)
        let eighty = groups.first { $0.host == "10.0.0.80" }
        XCTAssertEqual(eighty?.services.map(\.port), [8006, 8080])
    }

    func testSuggestionsRankExactThenPrefixThenSubstring() {
        let store = makeStore()
        store.importService(service("pve", "10.0.0.80", port: 8006))
        store.importService(service("pve-backup", "10.0.0.81", port: 8006))
        store.importService(service("my pve mirror", "10.0.0.82", port: 8006))

        let hits = store.suggestions(for: "pve", limit: 5)
        XCTAssertEqual(hits.map(\.alias), ["pve", "pve-backup", "my pve mirror"])
    }

    func testSuggestionsMatchTheAddressToo() {
        let store = makeStore()
        store.importService(service("Hypervisor", "10.0.0.80", port: 8006))
        XCTAssertEqual(store.suggestions(for: "10.0.0.80").map(\.alias), ["Hypervisor"])
        XCTAssertEqual(store.suggestions(for: "8006").map(\.alias), ["Hypervisor"])
        XCTAssertTrue(store.suggestions(for: "zzz").isEmpty)
    }

    /// A bare word that *is* an alias navigates. Whole-string only, or typing
    /// `mail` would stop searching for mail.
    func testOnlyAWholeAliasNavigates() {
        let store = makeStore()
        store.importService(service("proxmox", "10.0.0.80", port: 8006))
        XCTAssertEqual(store.exactMatch("proxmox")?.alias, "proxmox")
        XCTAssertEqual(store.exactMatch("  PROXMOX ")?.alias, "proxmox")
        XCTAssertNil(store.exactMatch("prox"))
        XCTAssertNil(store.exactMatch("proxmox vm"))
        XCTAssertNil(store.exactMatch(""))
    }

    func testAHostnameAlsoMatchesExactly() {
        let store = makeStore()
        var kept = service("Media", "10.0.0.42", port: 8096)
        kept.hostname = "meitner.lan."
        store.importService(kept)
        XCTAssertEqual(store.exactMatch("meitner.lan")?.alias, "Media")
    }

    // MARK: Trusting

    /// "Trust certificates" is the one button here with security consequences,
    /// so what it writes is pinned down: one entry per host, keyed on the
    /// fingerprint the scan actually saw.
    func testTrustingWritesOneEntryPerHostKeyedOnTheFingerprint() {
        let certificates = TrustedCertificateStore(
            file: JSONFileStore(url: directory.appendingPathComponent("certs.json")))
        let store = makeStore()
        store.importService(service("Proxmox", "10.0.0.80", port: 8006, fingerprint: "aaaa"))
        store.importService(service("Portainer", "10.0.0.42", port: 9443, fingerprint: "bbbb"))
        // Plain HTTP has nothing to trust.
        store.importService(service("Jellyfin", "10.0.0.42", port: 8096))

        for candidate in store.services where candidate.isHTTPS {
            guard let certificate = candidate.certificate, let host = candidate.url.host
            else { continue }
            certificates.trust(host: host, fingerprint: certificate.fingerprint)
        }

        XCTAssertEqual(certificates.certificates.count, 2)
        XCTAssertEqual(certificates.verdict(host: "10.0.0.80", fingerprint: "aaaa"), .trusted)
        XCTAssertEqual(certificates.verdict(host: "10.0.0.42", fingerprint: "bbbb"), .trusted)
        // The point of keying on the fingerprint: a *different* certificate on
        // a trusted host still has to ask.
        guard case .changed = certificates.verdict(host: "10.0.0.80", fingerprint: "dddd") else {
            return XCTFail("a changed certificate must re-prompt")
        }
    }

    func testOnlyHTTPSServicesWithACapturedCertificateAreTrustable() {
        let store = makeStore()
        store.importService(service("Jellyfin", "10.0.0.42", port: 8096))
        store.importService(service("Proxmox no cert", "10.0.0.80", port: 8006))
        store.importService(service("Portainer", "10.0.0.43", port: 9443, fingerprint: "bbbb"))
        let trustable = store.services.filter { $0.isHTTPS && $0.certificate != nil }
        XCTAssertEqual(trustable.map(\.alias), ["Portainer"])
    }

    // MARK: Persistence shape

    func testARecordMissingItsOptionalKeysStillDecodes() throws {
        let json = #"[{"alias":"pve","port":8006,"url":"https://10.0.0.80:8006"}]"#
        let decoded = try JSONDecoder().decode([LocalService].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].alias, "pve")
        XCTAssertEqual(decoded[0].host, "10.0.0.80")
        XCTAssertEqual(decoded[0].notes, "")
    }

    func testTheAddressLabelDropsADefaultPort() {
        var https = service("Site", "10.0.0.5", port: 443)
        https.hostname = "nas.lan"
        XCTAssertEqual(https.addressLabel, "nas.lan")
        let proxmox = service("Proxmox", "10.0.0.80", port: 8006)
        XCTAssertEqual(proxmox.addressLabel, "10.0.0.80:8006")
    }
}

extension LocalServiceStore {
    /// Argument order that reads better at the call site in tests.
    fileprivate func setNotes(_ service: LocalService, _ notes: String) {
        setNotes(notes, for: service)
    }
}
