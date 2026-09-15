//  LocalService.swift
//  What the LAN scanner finds, and what gets kept from it.
//
//  A homelab is a browser's most-visited set of sites, and it is the one set no
//  search engine can help you with: the addresses are private, the names only
//  resolve inside the house, and half of them are a port number you have to
//  remember. So the browser learns them itself — scan once, keep the ones that
//  matter under names you chose (#0089C).
//
//  Two layers, deliberately separate:
//    · `LANDiscoveredHost` / `LANDiscoveredPort` are *findings* — transient,
//      rebuilt by every scan, and never written to disk.
//    · `LocalService` is a *decision* — something you picked and named, which
//      persists and which the omnibox and the Local section read.

import Foundation

// MARK: - What a port is

/// A guess at what answers on a port, good enough to pick an icon and a scheme.
struct LANServiceKind: Equatable, Sendable {
    let name: String
    let symbol: String
    /// The URL scheme to open it with, or nil where it is not a web service.
    let scheme: String?

    var isWeb: Bool { scheme != nil }

    static let unknown = LANServiceKind(name: "Unknown", symbol: "questionmark.app", scheme: nil)
    static let http = LANServiceKind(name: "HTTP", symbol: "globe", scheme: "http")
    static let https = LANServiceKind(name: "HTTPS", symbol: "lock.shield", scheme: "https")
}

enum LANPortCatalog {
    /// The ports worth probing on a home network, and what each usually is.
    ///
    /// This is the homelab's actual shape rather than nmap's top-1000: the
    /// hypervisor, the media servers, the automation hub, the metrics stack and
    /// the handful of admin panels people really run. Everything else is a
    /// custom port, which the scanner takes as a list.
    static let known: [Int: LANServiceKind] = [
        22: LANServiceKind(name: "SSH", symbol: "terminal", scheme: nil),
        2222: LANServiceKind(name: "SSH (alt)", symbol: "terminal", scheme: nil),
        80: .http,
        443: .https,
        445: LANServiceKind(name: "SMB", symbol: "externaldrive.connected.to.line.below",
            scheme: nil),
        631: LANServiceKind(name: "IPP / CUPS", symbol: "printer", scheme: "http"),
        1883: LANServiceKind(name: "MQTT", symbol: "antenna.radiowaves.left.and.right",
            scheme: nil),
        3000: LANServiceKind(name: "Grafana / dev", symbol: "chart.xyaxis.line", scheme: "http"),
        3389: LANServiceKind(name: "RDP", symbol: "display", scheme: nil),
        5000: LANServiceKind(name: "HTTP (5000)", symbol: "globe", scheme: "http"),
        5432: LANServiceKind(name: "PostgreSQL", symbol: "cylinder.split.1x2", scheme: nil),
        5900: LANServiceKind(name: "VNC", symbol: "display", scheme: nil),
        8000: LANServiceKind(name: "HTTP (8000)", symbol: "globe", scheme: "http"),
        8006: LANServiceKind(name: "Proxmox", symbol: "server.rack", scheme: "https"),
        8080: LANServiceKind(name: "HTTP (8080)", symbol: "globe", scheme: "http"),
        8096: LANServiceKind(name: "Jellyfin", symbol: "play.rectangle", scheme: "http"),
        8123: LANServiceKind(name: "Home Assistant", symbol: "house", scheme: "http"),
        8384: LANServiceKind(name: "Syncthing", symbol: "arrow.triangle.2.circlepath",
            scheme: "http"),
        8443: LANServiceKind(name: "HTTPS (8443)", symbol: "lock.shield", scheme: "https"),
        9000: LANServiceKind(name: "Portainer", symbol: "shippingbox", scheme: "http"),
        9090: LANServiceKind(name: "Prometheus", symbol: "flame", scheme: "http"),
        9443: LANServiceKind(name: "Portainer (TLS)", symbol: "shippingbox", scheme: "https"),
        32400: LANServiceKind(name: "Plex", symbol: "play.tv", scheme: "http"),
    ]

    /// The default probe set, in ascending order so the results read naturally.
    static let defaultPorts: [Int] = known.keys.sorted()

    /// Ports below 1024 need the "1–1024" opt-in: sweeping them looks exactly
    /// like a port scan to anything watching, which on someone else's network
    /// is not a neighbourly thing to do unannounced.
    static let privilegedRange = 1...1024

    static func kind(for port: Int) -> LANServiceKind {
        if let known = known[port] { return known }
        // An unrecognised port that answers is still worth offering as a web
        // address, because most things that listen on a home network speak
        // HTTP. Nothing is assumed about TLS.
        return LANServiceKind(name: "Port \(port)", symbol: "questionmark.app", scheme: "http")
    }

    /// `https` where the port is conventionally TLS, `http` otherwise.
    static func scheme(for port: Int) -> String? { kind(for: port).scheme }
}

// MARK: - Findings

/// One open port on one host, with whatever the probe managed to learn.
struct LANDiscoveredPort: Identifiable, Equatable, Sendable {
    var port: Int
    /// `<title>` of `/`, where the port speaks HTTP and answered in time.
    var pageTitle: String?
    /// The leaf certificate, captured without trusting it.
    var certificate: LANCertificateInfo?

    var id: Int { port }
    var kind: LANServiceKind { LANPortCatalog.kind(for: port) }

    /// The address this port would open at, given a host.
    func url(host: String) -> URL? {
        guard let scheme = kind.scheme else { return nil }
        let isDefault = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        return URL(string: isDefault ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)")
    }
}

/// What we saw of a certificate. Captured during discovery *without* trusting
/// it — the fingerprint is the whole point, and trusting a certificate you have
/// not shown anyone would defeat #00889.
struct LANCertificateInfo: Codable, Equatable, Sendable {
    /// Lowercase hex SHA-256 of the leaf's DER bytes, the same number
    /// `openssl x509 -fingerprint -sha256` prints.
    var fingerprint: String
    var subject: String
    var expires: Date?

    var displayFingerprint: String {
        TrustedCertificate(host: "", fingerprint: fingerprint).displayFingerprint
    }
}

/// Everything found at one address.
struct LANDiscoveredHost: Identifiable, Equatable, Sendable {
    /// The IPv4 address, which is the identity — names come and go.
    var address: String
    /// Reverse-DNS or Bonjour name, if either answered.
    var hostname: String?
    /// Bonjour service types seen advertised from this address.
    var bonjourServices: [String] = []
    var ports: [LANDiscoveredPort] = []

    var id: String { address }

    var displayName: String { hostname ?? address }

    /// The nicest thing to call this host: the Bonjour/DNS name without its
    /// trailing dot, else the address.
    var shortName: String {
        guard let hostname else { return address }
        var trimmed = hostname
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed.isEmpty ? address : trimmed
    }
}

// MARK: - Decisions

/// A service you kept. The alias is the point: `proxmox` should be a thing you
/// can type, not an address you have to remember.
struct LocalService: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    /// What you call it. Seeded from the page title or the service kind.
    var alias: String
    /// The address it lives at — the IP, so a DHCP-renamed box still resolves.
    var host: String
    /// Reverse-DNS / Bonjour name at import time, kept for display.
    var hostname: String?
    var port: Int
    var url: URL
    var notes: String = ""
    var lastSeen: Date = Date()
    var addedAt: Date = Date()
    var certificate: LANCertificateInfo?
    /// Set when a re-scan found a different certificate than the one imported.
    /// Deliberately sticky: it is cleared by looking at it, not by time.
    var certificateChangedAt: Date?

    var kind: LANServiceKind { LANPortCatalog.kind(for: port) }
    var symbol: String { kind.symbol }

    /// `10.0.0.80:8006`, which is what the omnibox subtitle shows.
    var addressLabel: String {
        let name = hostname.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? host
        let isDefault = (port == 80 && url.scheme == "http") || (port == 443 && url.scheme == "https")
        return isDefault ? name : "\(name):\(port)"
    }

    var isHTTPS: Bool { url.scheme?.lowercased() == "https" }

    init(
        id: UUID = UUID(), alias: String, host: String, hostname: String? = nil, port: Int,
        url: URL, certificate: LANCertificateInfo? = nil
    ) {
        self.id = id
        self.alias = alias
        self.host = host
        self.hostname = hostname
        self.port = port
        self.url = url
        self.certificate = certificate
    }

    private enum CodingKeys: String, CodingKey {
        case id, alias, host, hostname, port, url, notes, lastSeen, addedAt
        case certificate, certificateChangedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `url`, `alias` and `port` are the record; without them there is
        // nothing to keep, so those three are the only required keys.
        url = try c.decode(URL.self, forKey: .url)
        alias = try c.decode(String.self, forKey: .alias)
        port = try c.decode(Int.self, forKey: .port)
        id = c.lenient(.id, UUID())
        host = c.lenient(.host, url.host ?? "")
        hostname = try? c.decodeIfPresent(String.self, forKey: .hostname)
        notes = c.lenient(.notes, "")
        lastSeen = c.lenient(.lastSeen, Date())
        addedAt = c.lenient(.addedAt, Date())
        certificate = try? c.decodeIfPresent(LANCertificateInfo.self, forKey: .certificate)
        certificateChangedAt = try? c.decodeIfPresent(Date.self, forKey: .certificateChangedAt)
    }

    /// The name to seed an import with: the page title where the probe got one,
    /// the Bonjour/DNS name where it did not, and the service kind as a last
    /// resort. Trimmed and capped, because some pages have essays for titles.
    static func suggestedAlias(
        host: LANDiscoveredHost, port: LANDiscoveredPort
    ) -> String {
        if let title = port.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            return String(title.prefix(48))
        }
        let base = host.shortName
        // `meitner` on its own is a better alias than `meitner — Port 8096`
        // when there is only one thing there; the kind disambiguates otherwise.
        if base != host.address { return "\(base) \(port.kind.name)" }
        return "\(port.kind.name) on \(host.address)"
    }
}
