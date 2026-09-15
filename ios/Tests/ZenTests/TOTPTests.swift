//  TOTPTests.swift
//  RFC 6238 and RFC 4648, against the RFCs' own vectors (#008AD).
//
//  A one-time password is either exactly right or completely useless, and it
//  fails in a way that looks like the *server's* clock being wrong. So this
//  runs every vector in RFC 6238 Appendix B — all three hash algorithms, all
//  six timestamps — rather than one happy-path check, and the base32 decoder
//  gets RFC 4648's vectors for the same reason: a decoder that is wrong only
//  on inputs whose length is not a multiple of eight is a decoder that works
//  on your test secret and not on a real one.

import XCTest

@testable import Zen

final class TOTPTests: XCTestCase {

    // MARK: RFC 6238 Appendix B

    /// The RFC's seeds are ASCII, not base32 — it gives them as
    /// "12345678901234567890" and expects those bytes.
    private let sha1Seed = Data("12345678901234567890".utf8)
    private let sha256Seed = Data("12345678901234567890123456789012".utf8)
    private let sha512Seed = Data(
        "1234567890123456789012345678901234567890123456789012345678901234".utf8)

    /// All eighteen vectors. Eight digits, 30-second step, T0 = 0.
    func testRFC6238Vectors() throws {
        let vectors: [(time: TimeInterval, sha1: String, sha256: String, sha512: String)] = [
            (59, "94287082", "46119246", "90693936"),
            (1_111_111_109, "07081804", "68084774", "25091201"),
            (1_111_111_111, "14050471", "67062674", "99943326"),
            (1_234_567_890, "89005924", "91819424", "93441116"),
            (2_000_000_000, "69279037", "90698825", "38618901"),
            (20_000_000_000, "65353130", "77737706", "47863826"),
        ]

        for vector in vectors {
            let date = Date(timeIntervalSince1970: vector.time)

            let sha1 = TOTPConfiguration(secret: sha1Seed, algorithm: .sha1, digits: 8, period: 30)
            XCTAssertEqual(
                TOTPGenerator.code(for: sha1, at: date), vector.sha1,
                "SHA1 at t=\(vector.time)")

            let sha256 = TOTPConfiguration(
                secret: sha256Seed, algorithm: .sha256, digits: 8, period: 30)
            XCTAssertEqual(
                TOTPGenerator.code(for: sha256, at: date), vector.sha256,
                "SHA256 at t=\(vector.time)")

            let sha512 = TOTPConfiguration(
                secret: sha512Seed, algorithm: .sha512, digits: 8, period: 30)
            XCTAssertEqual(
                TOTPGenerator.code(for: sha512, at: date), vector.sha512,
                "SHA512 at t=\(vector.time)")
        }
    }

    /// The six-digit form everybody actually uses is the eight-digit one
    /// truncated by the modulus, not by dropping characters — a distinction
    /// that matters because the leading digits are the ones that go.
    func testSixDigitsIsTheModulusNotASubstring() {
        let date = Date(timeIntervalSince1970: 59)
        let eight = TOTPConfiguration(secret: sha1Seed, algorithm: .sha1, digits: 8, period: 30)
        let six = TOTPConfiguration(secret: sha1Seed, algorithm: .sha1, digits: 6, period: 30)
        XCTAssertEqual(TOTPGenerator.code(for: eight, at: date), "94287082")
        XCTAssertEqual(TOTPGenerator.code(for: six, at: date), "287082")
    }

    /// A code with leading zeros must keep them. This is the classic bug: the
    /// integer is right, the string is five characters, and the site rejects it.
    func testCodesAreZeroPadded() {
        // t = 1111111109 with SHA1 gives 07081804 — a leading zero in the
        // RFC's own table, which is why this vector is the one to assert on.
        let configuration = TOTPConfiguration(
            secret: sha1Seed, algorithm: .sha1, digits: 8, period: 30)
        let code = TOTPGenerator.code(
            for: configuration, at: Date(timeIntervalSince1970: 1_111_111_109))
        XCTAssertEqual(code, "07081804")
        XCTAssertEqual(code.count, 8)
    }

    func testTheCodeIsStableAcrossItsWholePeriod() {
        let configuration = TOTPConfiguration(secret: sha1Seed, digits: 6, period: 30)
        let start = Date(timeIntervalSince1970: 1_111_111_080)  // a period boundary
        let code = TOTPGenerator.code(for: configuration, at: start)
        for offset in stride(from: 0.0, to: 30.0, by: 3.0) {
            XCTAssertEqual(
                TOTPGenerator.code(for: configuration, at: start.addingTimeInterval(offset)), code,
                "the code changed \(offset)s into its own period")
        }
        XCTAssertNotEqual(
            TOTPGenerator.code(for: configuration, at: start.addingTimeInterval(30)), code)
    }

    func testSecondsRemainingCountsDownWithinThePeriod() {
        let configuration = TOTPConfiguration(secret: sha1Seed, period: 30)
        XCTAssertEqual(
            TOTPGenerator.secondsRemaining(
                for: configuration, at: Date(timeIntervalSince1970: 1_111_111_080)),
            30)
        XCTAssertEqual(
            TOTPGenerator.secondsRemaining(
                for: configuration, at: Date(timeIntervalSince1970: 1_111_111_105)),
            5)
    }

    // MARK: otpauth URIs

    func testParsesAFullOTPAuthURI() throws {
        let configuration = try TOTPGenerator.configuration(
            from: "otpauth://totp/Vaultwarden:andy@example.com"
                + "?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Vaultwarden"
                + "&algorithm=SHA256&digits=8&period=60")
        XCTAssertEqual(configuration.secret, sha1Seed)
        XCTAssertEqual(configuration.algorithm, .sha256)
        XCTAssertEqual(configuration.digits, 8)
        XCTAssertEqual(configuration.period, 60)
        XCTAssertEqual(configuration.issuer, "Vaultwarden")
        XCTAssertEqual(configuration.account, "andy@example.com")
    }

    /// Everything optional is optional, and the defaults are the RFC's.
    func testOTPAuthDefaults() throws {
        let configuration = try TOTPGenerator.configuration(
            from: "otpauth://totp/andy@example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        XCTAssertEqual(configuration.algorithm, .sha1)
        XCTAssertEqual(configuration.digits, 6)
        XCTAssertEqual(configuration.period, 30)
        XCTAssertNil(configuration.issuer)
        XCTAssertEqual(configuration.account, "andy@example.com")
    }

    /// The `issuer` parameter wins over the label prefix when they disagree,
    /// which is the convention every authenticator follows.
    func testIssuerParameterBeatsTheLabelPrefix() throws {
        let configuration = try TOTPGenerator.configuration(
            from: "otpauth://totp/Old:andy@example.com"
                + "?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=New")
        XCTAssertEqual(configuration.issuer, "New")
        XCTAssertEqual(configuration.account, "andy@example.com")
    }

    /// A bare secret is the other shape vaults store, and it must reach the
    /// same configuration as the URI carrying it.
    func testABareBase32SecretIsAccepted() throws {
        let bare = try TOTPGenerator.configuration(from: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        XCTAssertEqual(bare.secret, sha1Seed)
        XCTAssertEqual(bare.algorithm, .sha1)
        XCTAssertEqual(bare.digits, 6)
    }

    /// Transcribed secrets arrive in groups with spaces, and lower-cased.
    func testABareSecretToleratesSpacingAndCase() throws {
        let spaced = try TOTPGenerator.configuration(
            from: "gezd gnbv gy3t qojq gezd gnbv gy3t qojq")
        XCTAssertEqual(spaced.secret, sha1Seed)
    }

    /// `otpauth://hotp` has a counter rather than a clock, so "the current
    /// code" is not a thing that exists — refusing beats showing a wrong one.
    func testHOTPIsRefusedRatherThanGuessed() {
        XCTAssertThrowsError(
            try TOTPGenerator.configuration(from: "otpauth://hotp/a?secret=MZXW6&counter=1")
        ) { error in
            XCTAssertEqual(
                error as? TOTPGenerator.Failure, .unsupportedScheme("otpauth://hotp"))
        }
    }

    func testRejectsNonsense() {
        XCTAssertThrowsError(try TOTPGenerator.configuration(from: "not base32: 1889!"))
        XCTAssertThrowsError(try TOTPGenerator.configuration(from: "   "))
        XCTAssertThrowsError(
            try TOTPGenerator.configuration(from: "otpauth://totp/a?secret="))
        XCTAssertThrowsError(
            try TOTPGenerator.configuration(from: "otpauth://totp/a?secret=MZXW6&algorithm=MD5"))
        XCTAssertThrowsError(
            try TOTPGenerator.configuration(from: "otpauth://totp/a?secret=MZXW6&digits=99"))
    }

    // MARK: RFC 4648 base32

    func testRFC4648Base32Vectors() throws {
        let vectors = [
            ("MY======", "f"),
            ("MZXQ====", "fo"),
            ("MZXW6===", "foo"),
            ("MZXW6YQ=", "foob"),
            ("MZXW6YTB", "fooba"),
            ("MZXW6YTBOI======", "foobar"),
        ]
        for (encoded, expected) in vectors {
            XCTAssertEqual(
                try TOTPGenerator.base32Decode(encoded), Data(expected.utf8),
                "decoding \(encoded)")
        }
    }

    /// Padding is optional in the wild — authenticator setup pages strip it.
    func testPaddingIsOptional() throws {
        XCTAssertEqual(try TOTPGenerator.base32Decode("MZXW6"), Data("foo".utf8))
        XCTAssertEqual(try TOTPGenerator.base32Decode("MZXW6YTBOI"), Data("foobar".utf8))
    }

    func testBase32RejectsCharactersOutsideTheAlphabet() {
        // 0, 1 and 8 are deliberately not in RFC 4648's base32 alphabet.
        XCTAssertThrowsError(try TOTPGenerator.base32Decode("MZXW6YTB0I"))
        XCTAssertThrowsError(try TOTPGenerator.base32Decode("!!!!"))
    }
}
