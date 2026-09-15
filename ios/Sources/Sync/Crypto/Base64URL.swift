//  Base64URL.swift
//  base64url (RFC 4648 §5) — unpadded, `-`/`_` instead of `+`/`/`.
//
//  Every identifier in the Firefox Sync stack is base64url: PKCE challenges,
//  JWE segments, JWK coordinates, the scoped key itself. Foundation only has
//  standard base64, so the translation lives here rather than being repeated
//  at each call site with a slightly different set of bugs.

import Foundation

enum Base64URL {

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts padded or unpadded input, and tolerates standard base64 too, so
    /// a server that pads (some do) still decodes.
    static func decode(_ string: String) -> Data? {
        var s =
            string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}

extension Data {
    var base64URLString: String { Base64URL.encode(self) }

    /// Lowercase hex — the encoding Sync uses for BSO HMACs.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var out = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }

    /// Constant-time equality. Comparing an HMAC with `==` leaks where the
    /// first differing byte is, which is exactly the thing an attacker wants.
    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(self, other) { difference |= a ^ b }
        return difference == 0
    }
}
