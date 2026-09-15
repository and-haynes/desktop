//  TOTP.swift
//  Time-based one-time passwords (RFC 6238), because a password manager that
//  cannot do the second factor sends you back to your phone's other app
//  (#008AD).
//
//  Both backends store the second factor in the same two shapes, so both are
//  accepted:
//
//    - a bare base32 secret, `JBSWY3DPEHPK3PXP`, which is what someone pastes
//      out of a "can't scan the code?" link;
//    - a full `otpauth://totp/Issuer:account?secret=…&digits=6&period=30`,
//      which is what a QR scanner writes, and which may override the defaults.
//
//  Implemented rather than pulled in: RFC 6238 is HMAC over an 8-byte counter
//  and a modulo, the RFC ships its own test vectors, and a dependency for
//  forty lines that must be exactly right is a worse trade than forty lines
//  checked against the vectors. `TOTPTests` runs all of the RFC's SHA-1,
//  SHA-256 and SHA-512 vectors.

import CryptoKit
import Foundation

// MARK: - Parameters

struct TOTPConfiguration: Equatable, Sendable {

    enum Algorithm: String, Equatable, Sendable {
        case sha1 = "SHA1"
        case sha256 = "SHA256"
        case sha512 = "SHA512"

        init?(loose raw: String) {
            // Vaults store "sha1", "SHA-1" and "SHA1" interchangeably.
            let cleaned = raw.uppercased().replacingOccurrences(of: "-", with: "")
            self.init(rawValue: cleaned)
        }
    }

    /// The shared secret, already base32-decoded.
    var secret: Data
    var algorithm: Algorithm
    var digits: Int
    var period: Int
    /// For the panel's subtitle: `Issuer (account)`.
    var issuer: String?
    var account: String?

    /// RFC 6238's defaults, which are also what every authenticator assumes
    /// when the URI omits them.
    init(
        secret: Data,
        algorithm: Algorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        issuer: String? = nil,
        account: String? = nil
    ) {
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.issuer = issuer
        self.account = account
    }
}

// MARK: - Generator

enum TOTPGenerator {

    enum Failure: LocalizedError, Equatable {
        case notBase32
        case emptySecret
        case unsupportedScheme(String)
        case unsupportedAlgorithm(String)
        case badParameter(String)

        var errorDescription: String? {
            switch self {
            case .notBase32:
                return "The one-time-password secret is not valid base32."
            case .emptySecret:
                return "The one-time-password secret is empty."
            case .unsupportedScheme(let scheme):
                return "\(scheme) one-time passwords are not supported — only otpauth://totp."
            case .unsupportedAlgorithm(let name):
                return "Unsupported one-time-password algorithm \"\(name)\"."
            case .badParameter(let detail):
                return "The one-time-password setup is invalid: \(detail)"
            }
        }
    }

    /// Parse whatever the vault had in its TOTP field.
    static func configuration(from stored: String) throws -> TOTPConfiguration {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptySecret }

        guard trimmed.lowercased().hasPrefix("otpauth://") else {
            // The bare-secret case. Spaces are how authenticator setup pages
            // print it ("jbsw y3dp ehpk 3pxp") and how it gets pasted.
            return TOTPConfiguration(secret: try base32Decode(trimmed))
        }
        return try configuration(fromURI: trimmed)
    }

    static func configuration(fromURI uri: String) throws -> TOTPConfiguration {
        guard let components = URLComponents(string: uri) else {
            throw Failure.badParameter("\(uri) is not a URL")
        }
        // `otpauth://hotp/…` is counter-based and has no wall clock, so it
        // cannot be shown as "the current code" — refusing is honest.
        let type = (components.host ?? "").lowercased()
        guard type == "totp" else { throw Failure.unsupportedScheme("otpauth://\(type)") }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value
        }

        guard let rawSecret = value("secret"), !rawSecret.isEmpty else {
            throw Failure.emptySecret
        }
        let secret = try base32Decode(rawSecret)

        var algorithm = TOTPConfiguration.Algorithm.sha1
        if let raw = value("algorithm") {
            guard let parsed = TOTPConfiguration.Algorithm(loose: raw) else {
                throw Failure.unsupportedAlgorithm(raw)
            }
            algorithm = parsed
        }

        var digits = 6
        if let raw = value("digits") {
            guard let parsed = Int(raw), (6...10).contains(parsed) else {
                throw Failure.badParameter("digits=\(raw)")
            }
            digits = parsed
        }

        var period = 30
        if let raw = value("period") {
            guard let parsed = Int(raw), parsed > 0, parsed <= 600 else {
                throw Failure.badParameter("period=\(raw)")
            }
            period = parsed
        }

        // The label is `/Issuer:account` or just `/account`, percent-encoded,
        // and the `issuer` parameter wins over the label's prefix when both
        // are present (RFC-adjacent convention; Google Authenticator's spec).
        let label = components.path.hasPrefix("/")
            ? String(components.path.dropFirst()) : components.path
        var issuer = value("issuer")
        var account: String? = label.isEmpty ? nil : label
        if let colon = label.firstIndex(of: ":") {
            let prefix = String(label[label.startIndex..<colon])
            let rest = String(label[label.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if issuer == nil, !prefix.isEmpty { issuer = prefix }
            account = rest.isEmpty ? nil : rest
        }

        return TOTPConfiguration(
            secret: secret,
            algorithm: algorithm,
            digits: digits,
            period: period,
            issuer: issuer,
            account: account)
    }

    /// The code for a moment in time. RFC 6238 §4: `T = floor(unix / period)`,
    /// HMAC it as a big-endian 64-bit counter, then RFC 4226's dynamic
    /// truncation.
    static func code(for configuration: TOTPConfiguration, at date: Date = Date()) -> String {
        let counter = UInt64(max(0, floor(date.timeIntervalSince1970 / Double(configuration.period))))
        return code(for: configuration, counter: counter)
    }

    static func code(for configuration: TOTPConfiguration, counter: UInt64) -> String {
        var bigEndian = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndian) { Data($0) }
        let key = SymmetricKey(data: configuration.secret)

        let digest: Data
        switch configuration.algorithm {
        case .sha1:
            digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            digest = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512:
            digest = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        // RFC 4226 §5.3 dynamic truncation: the low nibble of the last byte
        // picks a 4-byte window, whose top bit is masked off so the result is
        // positive regardless of the platform's integer signedness.
        let offset = Int(digest[digest.count - 1] & 0x0F)
        let truncated =
            (UInt32(digest[offset] & 0x7F) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])

        let modulus = UInt32(pow(10.0, Double(configuration.digits)))
        let value = truncated % modulus
        // Zero-padded: a code of 000123 is six digits, and trimming the zeros
        // is a bug people hit once and remember.
        return String(format: "%0\(configuration.digits)u", value)
    }

    /// Seconds until the current code rolls over, for the countdown ring.
    static func secondsRemaining(for configuration: TOTPConfiguration, at date: Date = Date())
        -> Int
    {
        let period = Double(configuration.period)
        return Int(period - date.timeIntervalSince1970.truncatingRemainder(dividingBy: period))
    }

    // MARK: base32

    /// RFC 4648 base32, upper- and lower-case, padding optional.
    ///
    /// Written out because `Data(base64Encoded:)` has no base32 sibling, and
    /// every authenticator secret in the world is base32.
    static func base32Decode(_ string: String) throws -> Data {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var lookup: [Character: UInt8] = [:]
        for (index, character) in alphabet.enumerated() { lookup[character] = UInt8(index) }

        var bits = 0
        var accumulator = 0
        var output = Data()
        var sawAny = false

        for character in string.uppercased() {
            // Spaces and dashes are how humans transcribe it; "=" is padding
            // and carries no bits.
            if character == " " || character == "-" || character == "=" { continue }
            guard let value = lookup[character] else { throw Failure.notBase32 }
            sawAny = true
            accumulator = (accumulator << 5) | Int(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }

        guard sawAny else { throw Failure.emptySecret }
        // A secret whose bits do not reach one byte is not a secret. Leftover
        // bits *below* a byte are legitimate base32 padding and are dropped.
        guard !output.isEmpty else { throw Failure.notBase32 }
        return output
    }
}
