//  LANScanner.swift
//  Finding what is actually on the home network.
//
//  The scan is deliberately two-phase, because the naive version is unusable:
//  a /24 × 23 ports is 5,800 connects, and a *dead* address does not refuse —
//  it never answers at all, so every one of them costs the full timeout. At 64
//  in flight that is a minute and a half of staring at a progress bar.
//
//  The saving grace is that "refused" and "silent" are different answers. A
//  host that is there but has nothing on port 80 sends a RST immediately; an
//  address with nothing at it times out. So:
//
//    1. **Liveness.** One pass over the whole subnet on three ports (80, 443,
//       22). Anything that either connects *or* refuses is a live host. ~250
//       addresses, seconds.
//    2. **Ports.** The full port list, but only against the handful of hosts
//       phase 1 found. Twenty hosts, not two hundred and fifty.
//
//  A host behind a DROP-everything firewall looks dead to phase 1 — that is the
//  known cost of the trade, and the UI says so rather than pretending the scan
//  is exhaustive. Bonjour runs alongside and can add hosts phase 1 missed.

import Foundation
import Network

// MARK: - Subnets

/// A parsed IPv4 network, and the addresses in it worth probing.
struct IPv4Subnet: Equatable, Sendable {
    /// The interface's own address, kept so the scan can mark "this device".
    let address: UInt32
    let prefixLength: Int

    /// Anything wider than this is not a home network, it is a mistake — and
    /// enumerating a /16 is 65,534 addresses nobody wants to wait for.
    static let maxPrefixLength = 22
    /// Beyond a /24 the scan is long enough to be worth warning about.
    static let comfortablePrefixLength = 24

    init(address: UInt32, prefixLength: Int) {
        self.address = address
        self.prefixLength = min(max(prefixLength, 0), 32)
    }

    /// From the dotted quads `getifaddrs` hands back.
    init?(address: String, netmask: String) {
        guard let addr = IPv4Subnet.parse(address), let mask = IPv4Subnet.parse(netmask)
        else { return nil }
        self.init(address: addr, prefixLength: IPv4Subnet.prefixLength(ofMask: mask))
    }

    /// The prefix actually scanned, after the /22 cap.
    var effectivePrefixLength: Int { max(prefixLength, Self.maxPrefixLength) }

    var isWiderThanComfortable: Bool { effectivePrefixLength < Self.comfortablePrefixLength }
    var wasClamped: Bool { prefixLength < Self.maxPrefixLength }

    var mask: UInt32 {
        effectivePrefixLength == 0 ? 0 : ~UInt32(0) << (32 - effectivePrefixLength)
    }

    var networkAddress: UInt32 { address & mask }
    var broadcastAddress: UInt32 { networkAddress | ~mask }

    /// Every usable host address, network and broadcast excluded. A /31 or /32
    /// has no usable range in the classic sense, so the address itself is it.
    var hostAddresses: [String] {
        guard effectivePrefixLength <= 30 else { return [Self.string(address)] }
        let first = networkAddress + 1
        let last = broadcastAddress - 1
        guard first <= last else { return [Self.string(address)] }
        return (first...last).map(Self.string)
    }

    var hostCount: Int {
        guard effectivePrefixLength <= 30 else { return 1 }
        return Int(broadcastAddress - networkAddress) - 1
    }

    /// `10.0.0.0/24`, for the UI.
    var displayCIDR: String {
        "\(Self.string(networkAddress))/\(effectivePrefixLength)"
    }

    static func string(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    static func parse(_ dotted: String) -> UInt32? {
        let parts = dotted.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let byte = UInt8(part) else {
                return nil
            }
            out = (out << 8) | UInt32(byte)
        }
        return out
    }

    /// Count the leading ones. A non-contiguous mask is not a thing we handle;
    /// counting leading ones degrades gracefully if we ever meet one.
    static func prefixLength(ofMask mask: UInt32) -> Int {
        var count = 0
        var bit: UInt32 = 0x8000_0000
        while bit != 0, mask & bit != 0 {
            count += 1
            bit >>= 1
        }
        return count
    }
}

// MARK: - The Wi-Fi interface

enum NetworkInterface {
    /// Interfaces that are never the home network: VPN tunnels, AirDrop's
    /// peer-to-peer links, and the internal service links macOS keeps up.
    /// Scanning any of them is either pointless or somebody else's network.
    private static let ignoredPrefixes = ["utun", "awdl", "llw", "anpi", "ipsec", "ap1"]

    /// The device's own IPv4 address and netmask on the network worth scanning.
    ///
    /// `en0` is Wi-Fi on a real iPhone, so it is preferred outright. In the
    /// *simulator* there is no en0 with an address — the host Mac's LAN sits on
    /// whichever `enN` the hardware landed on — so the fallback matters as much
    /// as the preference does, and it is deliberately fussy: a private address
    /// on a real, non-tunnel interface, or nothing.
    static func wifiIPv4() -> (address: String, netmask: String)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var privateFallback: (String, String)?
        var anyFallback: (String, String)?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = current.pointee.ifa_flags
            guard let addr = current.pointee.ifa_addr,
                addr.pointee.sa_family == UInt8(AF_INET),
                flags & UInt32(IFF_UP) != 0,
                flags & UInt32(IFF_LOOPBACK) == 0,
                // A point-to-point link has no subnet to sweep.
                flags & UInt32(IFF_POINTOPOINT) == 0,
                let mask = current.pointee.ifa_netmask
            else { continue }

            let name = String(cString: current.pointee.ifa_name)
            guard !ignoredPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            guard let address = presentation(of: addr), let netmask = presentation(of: mask)
            else { continue }

            if name == "en0" { return (address, netmask) }
            if LANHost.isLocalNetwork(address) {
                if privateFallback == nil { privateFallback = (address, netmask) }
            } else if anyFallback == nil {
                anyFallback = (address, netmask)
            }
        }
        return privateFallback ?? anyFallback
    }

    private static func presentation(of addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let size = socklen_t(addr.pointee.sa_len)
        guard
            getnameinfo(
                addr, size, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return String(cString: buffer)
    }

    /// Reverse DNS, which on a home network is usually the router's DHCP
    /// hostname table. Best effort and short — a resolver that does not answer
    /// must not hold up a scan.
    static func reverseDNS(of address: String) -> String? {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        guard let packed = IPv4Subnet.parse(address) else { return nil }
        sin.sin_addr.s_addr = packed.bigEndian

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = withUnsafePointer(to: &sin) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(
                    sa, socklen_t(MemoryLayout<sockaddr_in>.size), &host,
                    socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0
            }
        }
        guard ok else { return nil }
        let name = String(cString: host)
        return name == address || name.isEmpty ? nil : name
    }
}

// MARK: - Probing one port

enum LANProbeResult: Equatable, Sendable {
    /// Something accepted the connection.
    case open
    /// The host is there and said no — which still proves it exists.
    case refused
    /// Nothing answered inside the timeout.
    case silent
}

enum LANProbe {
    /// A single TCP connect with a hard deadline.
    ///
    /// `NWConnection` has no connect timeout of its own, so the deadline is a
    /// race between the state handler and a sleeping task. Whichever gets there
    /// first resumes the continuation; the flag makes the second a no-op,
    /// because resuming twice is a crash rather than a bug you find later.
    static func connect(
        host: String, port: Int, timeout: TimeInterval
    ) async -> LANProbeResult {
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port))
        else { return .silent }
        let parameters = NWParameters.tcp
        // We want to know whether *this* address answers, not whether some
        // proxy will answer for it.
        parameters.preferNoProxies = true
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: nwPort, using: parameters)

        let box = ProbeBox()
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<LANProbeResult, Never>) in
            box.finish = { result in
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.complete(.open)
                case .failed(let error), .waiting(let error):
                    // A refusal is information: the host is up and said no.
                    // Anything else — no route, host down, or `waiting`, which
                    // means Network will keep retrying for a minute — is a
                    // silent address as far as a scan is concerned.
                    if case .posix(let code) = error, code == .ECONNREFUSED {
                        box.complete(.refused)
                    } else {
                        box.complete(.silent)
                    }
                case .cancelled:
                    box.complete(.silent)
                default:
                    break
                }
            }
            connection.start(queue: Self.queue)
            Self.queue.asyncAfter(deadline: .now() + timeout) { box.complete(.silent) }
        }
    }

    /// One queue for every probe. `NWConnection` callbacks are cheap and the
    /// work is all waiting, so a concurrent queue here is a thread explosion
    /// for nothing.
    private static let queue = DispatchQueue(label: "app.zen.lanscan", qos: .userInitiated)

    /// Holds the continuation's resume behind a lock, so the timeout and the
    /// state handler racing each other is safe rather than fatal.
    private final class ProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var finish: ((LANProbeResult) -> Void)?

        func complete(_ result: LANProbeResult) {
            lock.lock()
            let alreadyDone = done
            done = true
            let finish = self.finish
            lock.unlock()
            guard !alreadyDone else { return }
            finish?(result)
        }
    }
}

// MARK: - HTTP fingerprinting

/// Fetches `/` on a web-looking port to read its `<title>`, and captures the
/// leaf certificate on the way past.
///
/// The session trusts anything **for this request only**. That is the whole
/// point: a homelab's certificates are self-signed, and refusing to look at
/// them would mean the scan could never report what is actually there. Nothing
/// is written to `TrustedCertificateStore` — approving a certificate stays the
/// deliberate act it is in #00889, and the fingerprint this captures is what
/// you would compare it against.
final class LANHTTPProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var certificates: [String: LANCertificateInfo] = [:]

    init(timeout: TimeInterval = 3) {
        self.timeout = timeout
        super.init()
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Returns the page title, if the port spoke HTTP and said something.
    func probe(url: URL) async -> (title: String?, certificate: LANCertificateInfo?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // A HEAD would be cheaper but gives no title, and a scan that reports
        // "Port 8096" instead of "Jellyfin" is barely worth running.
        request.httpMethod = "GET"
        request.setValue("close", forHTTPHeaderField: "Connection")
        let key = certificateKey(for: url)
        guard let (data, _) = try? await session.data(for: request) else {
            return (nil, certificate(for: key))
        }
        // A megabyte of someone's SPA is not needed to find a <title>.
        let head = data.prefix(64 * 1024)
        return (Self.title(in: head), certificate(for: key))
    }

    func invalidate() { session.invalidateAndCancel() }

    private func certificateKey(for url: URL) -> String {
        "\(url.host ?? "")|\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }

    private func certificate(for key: String) -> LANCertificateInfo? {
        lock.lock()
        defer { lock.unlock() }
        return certificates[key]
    }

    /// Pulls `<title>` out of the first chunk of the response without dragging
    /// in an HTML parser for one tag.
    static func title(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        let lower = text.lowercased()
        guard let openRange = lower.range(of: "<title"),
            let gt = text[openRange.upperBound...].firstIndex(of: ">"),
            let closeRange = lower.range(of: "</title>", range: gt..<text.endIndex)
        else { return nil }
        let raw = String(text[text.index(after: gt)..<closeRange.lowerBound])
        let decoded =
            raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let collapsed = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    // MARK: URLSessionDelegate

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let space = challenge.protectionSpace
        let key = "\(space.host)|\(space.port)"
        if let info = Self.info(from: trust) {
            lock.lock()
            certificates[key] = info
            lock.unlock()
        }
        // Discovery only. See the note on the class.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// Fingerprint, subject and expiry off the leaf, using the same SHA-256 the
    /// certificate sheet shows so the two numbers can be compared by eye.
    static func info(from trust: SecTrust) -> LANCertificateInfo? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        let subject =
            (SecCertificateCopySubjectSummary(leaf) as String?)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
        return LANCertificateInfo(
            fingerprint: CertificateFingerprint.sha256(of: data),
            subject: subject.isEmpty ? "Unknown" : subject,
            expires: expiry(of: leaf))
    }

    private static func expiry(of certificate: SecCertificate) -> Date? {
        X509Validity.notAfter(inDER: SecCertificateCopyData(certificate) as Data)
    }
}

// MARK: - notAfter, the hard way

/// Reading a certificate's expiry date out of its DER bytes.
///
/// macOS has `SecCertificateCopyValues` for this; iOS has never exposed it, and
/// the alternatives are worse — dragging in a whole ASN.1 library for one field,
/// or shipping the expiry as "unknown" in a sheet whose entire job is telling
/// you about a certificate. So: a walk down exactly the path this one value
/// sits on, and `nil` the moment anything is not the shape expected.
///
///     Certificate  ::= SEQUENCE { tbsCertificate, signatureAlgorithm, ... }
///     TBSCertificate ::= SEQUENCE {
///         [0] version, serialNumber, signature, issuer,
///         validity  Validity, ... }
///     Validity     ::= SEQUENCE { notBefore Time, notAfter Time }
///     Time         ::= UTCTime | GeneralizedTime
///
/// `Validity` is found by shape rather than by counting fields: it is the first
/// SEQUENCE inside the TBS whose two children are both time values. Counting
/// would mean handling the optional explicit `[0] version` tag, which is one
/// more thing to get wrong for no gain.
enum X509Validity {
    static func notAfter(inDER der: Data) -> Date? {
        let bytes = [UInt8](der)
        // Certificate SEQUENCE -> TBSCertificate SEQUENCE.
        guard let certificate = element(in: bytes, at: 0), certificate.tag == 0x30,
            let tbs = element(in: bytes, at: certificate.contentStart), tbs.tag == 0x30
        else { return nil }

        var cursor = tbs.contentStart
        let end = tbs.contentStart + tbs.length
        while cursor < end, let child = element(in: bytes, at: cursor) {
            defer { cursor = child.contentStart + child.length }
            guard child.tag == 0x30 else { continue }
            guard let notBefore = element(in: bytes, at: child.contentStart),
                isTime(notBefore.tag),
                let notAfter = element(
                    in: bytes, at: notBefore.contentStart + notBefore.length),
                isTime(notAfter.tag)
            else { continue }
            let raw = bytes[notAfter.contentStart..<(notAfter.contentStart + notAfter.length)]
            return date(from: String(decoding: raw, as: UTF8.self), generalized: notAfter.tag == 0x18)
        }
        return nil
    }

    private static func isTime(_ tag: UInt8) -> Bool { tag == 0x17 || tag == 0x18 }

    private struct Element {
        let tag: UInt8
        let contentStart: Int
        let length: Int
    }

    /// One tag-length-value triple. Handles the long-form length DER uses past
    /// 127 bytes; refuses anything indefinite, which DER forbids anyway.
    private static func element(in bytes: [UInt8], at offset: Int) -> Element? {
        guard offset + 1 < bytes.count else { return nil }
        let tag = bytes[offset]
        let first = bytes[offset + 1]
        if first & 0x80 == 0 {
            let length = Int(first)
            guard offset + 2 + length <= bytes.count else { return nil }
            return Element(tag: tag, contentStart: offset + 2, length: length)
        }
        let byteCount = Int(first & 0x7F)
        guard byteCount > 0, byteCount <= 4, offset + 2 + byteCount <= bytes.count else {
            return nil
        }
        var length = 0
        for index in 0..<byteCount { length = (length << 8) | Int(bytes[offset + 2 + index]) }
        guard offset + 2 + byteCount + length <= bytes.count else { return nil }
        return Element(tag: tag, contentStart: offset + 2 + byteCount, length: length)
    }

    /// `YYMMDDHHMMSSZ` (UTCTime) or `YYYYMMDDHHMMSSZ` (GeneralizedTime).
    /// RFC 5280 pins the two-digit year: 50-99 is 19xx, 00-49 is 20xx.
    static func date(from string: String, generalized: Bool) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = generalized ? "yyyyMMddHHmmss'Z'" : "yyMMddHHmmss'Z'"
        return formatter.date(from: string)
    }
}
