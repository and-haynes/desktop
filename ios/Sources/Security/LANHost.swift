//  LANHost.swift
//  Deciding whether a host is "something on your home network".
//
//  This is the gate on the friendly certificate prompt. A homelab box with a
//  self-signed cert should not get the same interstitial as a public site
//  failing TLS — one is normal, the other is an attack until proven otherwise.
//  So the classifier has to be conservative in exactly one direction: it may
//  miss a LAN host (you get the stern prompt, which is merely annoying), but it
//  must never call a public host local.

import Foundation

enum LANHost {
    /// Suffixes reserved or conventionally used for private networks.
    /// `.local` is mDNS, `.home.arpa` is the RFC 8375 reservation, and the
    /// rest are what home routers actually hand out.
    static let localSuffixes: [String] = [
        ".lan", ".local", ".home.arpa", ".internal", ".home",
    ]

    /// True when `host` is on the local network by name or by address.
    static func isLocalNetwork(_ rawHost: String?) -> Bool {
        guard let host = normalise(rawHost) else { return false }

        if host == "localhost" { return true }
        if let v4 = IPv4(host) { return v4.isPrivate }
        if isLocalIPv6(host) { return true }

        // A literal IP that is *not* private is public, full stop — do not let
        // it fall through to the single-label rule below.
        if IPv4(host) != nil || host.contains(":") { return false }

        for suffix in localSuffixes where host.hasSuffix(suffix) {
            // Guard against a public name that merely ends in the letters,
            // e.g. "mylocal" must not match ".local".
            return host.count > suffix.count
        }

        // A single-label name has no public DNS meaning — it can only be
        // resolved by the local resolver, so it is local by construction.
        if !host.contains(".") { return true }

        return false
    }

    /// Lowercased, trailing dot and brackets removed. Returns nil for empty.
    private static func normalise(_ rawHost: String?) -> String? {
        guard var host = rawHost?.lowercased().trimmingCharacters(in: .whitespaces),
            !host.isEmpty
        else { return nil }
        // A fully-qualified name may carry a trailing root dot.
        while host.hasSuffix(".") { host.removeLast() }
        // URLComponents hands IPv6 literals back bracketed.
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host.isEmpty ? nil : host
    }

    /// Minimal dotted-quad parser. Deliberately strict: four decimal octets,
    /// nothing else, so "1.2.3.4.5" and "10.0.0.x" are not addresses.
    private struct IPv4 {
        let octets: [UInt8]

        init?(_ string: String) {
            let parts = string.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var out: [UInt8] = []
            for part in parts {
                // Reject "01" and "+1"; only plain decimal counts.
                guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = UInt8(part)
                else { return nil }
                out.append(value)
            }
            octets = out
        }

        var isPrivate: Bool {
            switch (octets[0], octets[1]) {
            case (127, _): return true                 // loopback
            case (10, _): return true                  // RFC1918 10/8
            case (172, 16...31): return true           // RFC1918 172.16/12
            case (192, 168): return true               // RFC1918 192.168/16
            case (169, 254): return true               // link-local
            default: return false
            }
        }
    }

    /// `::1` loopback, `fe80::/10` link-local, and `fc00::/7` unique-local —
    /// the v6 analogues of the v4 ranges above.
    private static func isLocalIPv6(_ host: String) -> Bool {
        guard host.contains(":") else { return false }
        // Strip any zone index ("fe80::1%en0").
        let address = host.split(separator: "%").first.map(String.init) ?? host
        if address == "::1" { return true }
        let first = address.split(separator: ":").first.map(String.init) ?? ""
        guard !first.isEmpty, let group = UInt16(first, radix: 16) else { return false }
        if group & 0xFFC0 == 0xFE80 { return true }  // fe80::/10
        if group & 0xFE00 == 0xFC00 { return true }  // fc00::/7
        return false
    }

    /// A name to show the user — the bare host, which is what they typed.
    static func displayName(_ host: String?) -> String {
        normalise(host) ?? "This site"
    }
}
