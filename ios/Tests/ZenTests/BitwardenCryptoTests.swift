//  BitwardenCryptoTests.swift
//  Bitwarden's client-side crypto, pinned against vectors produced outside
//  this codebase (#008AD).
//
//  Nothing here touches the network — this file is pure maths.
//
//  The vectors are carried over verbatim from Ghostty's `BitwardenTests`,
//  which is the point rather than a shortcut: two independent Swift ports
//  agreeing with each other proves nothing, but both agreeing with the same
//  externally-computed numbers means either one can talk to the real vault.
//  Their provenance, restated so it is not a link to somewhere else:
//
//    * The PBKDF2 vector is Bitwarden's own published one — email
//      "test@bitwarden.com", master password "test", PBKDF2-SHA256 at 100 000
//      iterations — and the expected values were computed three ways before
//      being written down (python `hashlib.pbkdf2_hmac`; a hand-written PBKDF2
//      loop over hmac/sha256 with no library PBKDF2 at all; and
//      `openssl kdf … PBKDF2`). All three agreed.
//    * The stretched halves were cross-checked against
//      `openssl kdf -kdfopt mode:EXPAND_ONLY -kdfopt hexinfo:656e63 … HKDF`.
//    * `recordedEncString` was produced with `openssl enc -aes-256-cbc` plus a
//      separately computed HMAC-SHA256, so it pins the *parser* rather than
//      merely proving the parser agrees with the writer.
//
//  All of the above were recomputed from scratch before this file was written,
//  rather than trusted because they were already in a test somewhere.

import CryptoKit
import XCTest

@testable import Zen

// MARK: - Fixtures

enum BitwardenFixtures {

    // MARK: Published KDF vector

    static let vectorEmail = "test@bitwarden.com"
    static let vectorPassword = "test"
    static let vectorIterations = 100_000
    static let vectorMasterKey = "/0MLlY7udF3gHWTpZe2wtu7VN/LRt33RbthSJI8zjko="
    static let vectorMasterPasswordHash = "/fLMc6m0bwpU1bYko8NY/gl/+SaxfSGGQc6arJoDOaE="
    static let vectorStretchedEnc = "izSR78Rp39xUN48fZKkx9DV7f+i5z2AYCYyRJCAE8ms="
    static let vectorStretchedMac = "hdcV8uLHaJyTtTBUKw7ZtZKuk+LbcAWzZIa1EdmiWPs="

    /// The 64-byte user key every cipher fixture in `BitwardenProviderTests` is
    /// encrypted with. It is what `protectedUserKey` below unwraps to.
    static let userKeyBase64 =
        "AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dzj6vH4/wYNFBsiKTA3PkVMU1phaG92fYSLkpmgp661vA=="

    static func userKey() throws -> BitwardenSymmetricKey {
        let data = try XCTUnwrap(Data(base64Encoded: userKeyBase64))
        return try BitwardenSymmetricKey(concatenated: data)
    }

    /// The account's protected key exactly as the homelab's Vaultwarden
    /// returns it, openable with the stretched master key for password "test"
    /// at **600 000** iterations — which is what a live `vault.lan` prelogin
    /// reports. The 100 000-iteration vector above is a different account.
    static let protectedUserKey =
        "2.oKGio6SlpqeoqaqrrK2urw==|Cfjw2Zd8yCcwooLZlL8Vbt5EMJDhqsu4bKxcnWqehgJMMiAlau+EoJkPMxI7cL"
        + "HXpa6u1Vj38j5cWFjrkQPsO9eYFPYlgPntKRffM8gU1X8=|aGjOYrhPYeQETqJ2QeZdHKW2DGy0bG0HZtJcZyiz"
        + "4i4="

    static let liveKDFIterations = 600_000

    // MARK: Recorded EncString
    //
    //   iv  = 000102030405060708090a0b0c0d0e0f
    //   key = stretched master key of the published vector above
    //   ct  = openssl enc -aes-256-cbc -K <enc half> -iv <iv>
    //   mac = HMAC-SHA256(<mac half>, iv || ct)

    static let recordedPlaintext = "ghostty-encstring-fixture-v1"
    static let recordedEncString =
        "2.AAECAwQFBgcICQoLDA0ODw==|jTy7gpypFURKBlYUcqNcVmyyv75FJVem2Nyjk6BpYKU=|"
        + "yHl5XIMSOJRsTrkw57LOESNsklwC2J1ehqYgJoR6/5g="

    /// The stretched master key of the published vector, which is what the
    /// recorded EncString above was sealed under.
    static func vectorStretchedKey() throws -> BitwardenSymmetricKey {
        let masterKeyData = try XCTUnwrap(Data(base64Encoded: vectorMasterKey))
        return BitwardenCrypto.stretch(masterKey: SymmetricKey(data: masterKeyData))
    }
}

/// Records what the Argon2 seam is handed, so the salt rule can be asserted
/// without an Argon2 implementation being present.
///
/// `@unchecked Sendable`: `Argon2Hashing` is `Sendable` so it can cross into
/// the provider actor, and a recorder is mutable by definition. It is only
/// ever touched from one test at a time.
final class RecordingArgon2: Argon2Hashing, @unchecked Sendable {
    var salt: Data?
    var iterations: Int?
    var memoryKiB: Int?
    var parallelism: Int?
    var outputByteCount: Int?

    func hash(
        password: Data,
        salt: Data,
        iterations: Int,
        memoryKiB: Int,
        parallelism: Int,
        outputByteCount: Int
    ) throws -> Data {
        self.salt = salt
        self.iterations = iterations
        self.memoryKiB = memoryKiB
        self.parallelism = parallelism
        self.outputByteCount = outputByteCount
        return Data(repeating: 0x42, count: outputByteCount)
    }
}

// MARK: - Master key and stretching

final class BitwardenCryptoTests: XCTestCase {

    func testMasterKeyMatchesPublishedVector() throws {
        let key = try BitwardenCrypto.masterKey(
            password: BitwardenFixtures.vectorPassword,
            email: BitwardenFixtures.vectorEmail,
            kdf: .pbkdf2(iterations: BitwardenFixtures.vectorIterations)
        )
        XCTAssertEqual(key.rawData.base64EncodedString(), BitwardenFixtures.vectorMasterKey)
        XCTAssertEqual(key.rawData.count, 32)
    }

    func testMasterPasswordHashMatchesPublishedVector() throws {
        let key = try BitwardenCrypto.masterKey(
            password: BitwardenFixtures.vectorPassword,
            email: BitwardenFixtures.vectorEmail,
            kdf: .pbkdf2(iterations: BitwardenFixtures.vectorIterations)
        )
        let hash = try BitwardenCrypto.masterPasswordHash(
            masterKey: key,
            password: BitwardenFixtures.vectorPassword
        )
        XCTAssertEqual(hash, BitwardenFixtures.vectorMasterPasswordHash)
        // The hash must not be the master key itself — that would hand the
        // vault's root secret to the server.
        XCTAssertNotEqual(hash, BitwardenFixtures.vectorMasterKey)
    }

    func testEmailSaltIsTrimmedAndLowercased() throws {
        let canonical = try BitwardenCrypto.masterKey(
            password: "test",
            email: "test@bitwarden.com",
            kdf: .pbkdf2(iterations: 5_000)
        )
        let messy = try BitwardenCrypto.masterKey(
            password: "test",
            email: "  TEST@Bitwarden.COM \n",
            kdf: .pbkdf2(iterations: 5_000)
        )
        XCTAssertEqual(canonical.rawData, messy.rawData)
    }

    func testPBKDF2RejectsZeroIterations() {
        XCTAssertThrowsError(
            try BitwardenCrypto.masterKey(
                password: "x", email: "a@b.c", kdf: .pbkdf2(iterations: 0))
        ) { error in
            XCTAssertTrue("\(error)".contains("at least 1"), "\(error)")
        }
    }

    func testPBKDF2RejectsAnEmptySalt() {
        XCTAssertThrowsError(
            try BitwardenCrypto.masterKey(
                password: "x", email: "   ", kdf: .pbkdf2(iterations: 5_000))
        ) { error in
            XCTAssertTrue("\(error)".contains("KDF salt"), "\(error)")
        }
    }

    // MARK: Argon2

    func testArgon2SaltIsSHA256OfEmailNotTheEmail() throws {
        let recorder = RecordingArgon2()
        _ = try BitwardenCrypto.masterKey(
            password: "test",
            email: "  TEST@Bitwarden.com ",
            kdf: .argon2id(iterations: 3, memoryMiB: 64, parallelism: 4),
            argon2: recorder
        )
        let expected = Data(SHA256.hash(data: Data("test@bitwarden.com".utf8)))
        XCTAssertEqual(recorder.salt, expected)
        XCTAssertNotEqual(recorder.salt, Data("test@bitwarden.com".utf8))
        // MiB on the wire, KiB into Argon2.
        XCTAssertEqual(recorder.memoryKiB, 64 * 1024)
        XCTAssertEqual(recorder.iterations, 3)
        XCTAssertEqual(recorder.parallelism, 4)
        XCTAssertEqual(recorder.outputByteCount, 32)
    }

    func testArgon2UnavailableFailsWithAnActionableMessage() {
        XCTAssertThrowsError(
            try BitwardenCrypto.masterKey(
                password: "test",
                email: "test@bitwarden.com",
                kdf: .argon2id(iterations: 3, memoryMiB: 64, parallelism: 4)
            )
        ) { error in
            guard case VaultError.crypto(let detail) = error else {
                return XCTFail("expected a crypto error, got \(error)")
            }
            XCTAssertTrue(detail.contains("Argon2id is not available in this build"), detail)
            // An error that only says "failed" is not actionable; this one must
            // tell the user what to do instead.
            XCTAssertTrue(detail.contains("PBKDF2"), detail)
        }
    }

    // MARK: Stretching

    func testStretchMatchesPublishedVectorAndSplitsCleanly() throws {
        let stretched = try BitwardenFixtures.vectorStretchedKey()

        XCTAssertEqual(
            stretched.encKey.rawData.base64EncodedString(),
            BitwardenFixtures.vectorStretchedEnc)
        XCTAssertEqual(
            stretched.macKey.rawData.base64EncodedString(),
            BitwardenFixtures.vectorStretchedMac)
        XCTAssertEqual(stretched.encKey.rawData.count, 32)
        XCTAssertEqual(stretched.macKey.rawData.count, 32)
        // The two halves must differ; one key used for both jobs would break
        // the encrypt-then-MAC construction.
        XCTAssertNotEqual(stretched.encKey.rawData, stretched.macKey.rawData)
        XCTAssertEqual(stretched.concatenated.count, 64)
    }

    func testStretchIsDeterministic() throws {
        let first = try BitwardenFixtures.vectorStretchedKey()
        let second = try BitwardenFixtures.vectorStretchedKey()
        XCTAssertEqual(first.concatenated, second.concatenated)
    }

    func testSymmetricKeyRejectsWrongLength() {
        XCTAssertThrowsError(
            try BitwardenSymmetricKey(concatenated: Data(repeating: 0, count: 32))
        ) { error in
            XCTAssertTrue("\(error)".contains("64 bytes"), "\(error)")
        }
    }

    func testSymmetricKeySplitSurvivesASlicedBuffer() throws {
        // A `Data` slice keeps its parent's indices; splitting one with
        // prefix/suffix on raw indices is a classic silent corruption.
        let padded = Data(repeating: 0xEE, count: 8) + Data((0..<64).map { UInt8($0) })
        let slice = padded[8...]
        let key = try BitwardenSymmetricKey(concatenated: slice)
        XCTAssertEqual(Array(key.encKey.rawData), Array(0..<32).map { UInt8($0) })
        XCTAssertEqual(Array(key.macKey.rawData), Array(32..<64).map { UInt8($0) })
    }
}

// MARK: - EncString

final class BitwardenEncStringTests: XCTestCase {

    func testRecordedFixtureDecrypts() throws {
        let key = try BitwardenFixtures.vectorStretchedKey()
        let parsed = try EncString.parse(BitwardenFixtures.recordedEncString)
        XCTAssertEqual(parsed.type, .aesCbc256_HmacSha256_B64)
        XCTAssertEqual(parsed.iv.count, 16)
        XCTAssertEqual(
            try parsed.decryptToString(key: key), BitwardenFixtures.recordedPlaintext)
    }

    func testDescriptionRoundTripsTheRecordedFixture() throws {
        let parsed = try EncString.parse(BitwardenFixtures.recordedEncString)
        XCTAssertEqual(parsed.description, BitwardenFixtures.recordedEncString)
    }

    func testRoundTrip() throws {
        let key = try BitwardenFixtures.vectorStretchedKey()
        // No empty string in this list, and not by oversight: Zen's shared
        // `AESCBC` hands CommonCrypto a nil base address for empty `Data`,
        // which is a parameter error rather than a one-block pad. Nothing ever
        // writes an empty field — `BitwardenVaultProvider.makeRequest` maps an
        // empty username or password to a **missing** field, which is what
        // Bitwarden's own clients do — so the case is unreachable rather than
        // merely untested.
        let plaintexts = [
            "a",
            "hello",
            String(repeating: "x", count: 16),
            String(repeating: "y", count: 1024),
            "ünïcødé ✅",
        ]
        for plaintext in plaintexts {
            let sealed = try EncString.encrypt(plaintext, key: key)
            let reparsed = try EncString.parse(sealed.description)
            XCTAssertEqual(try reparsed.decryptToString(key: key), plaintext)
        }
    }

    func testEncryptUsesAFreshIVEachTime() throws {
        let key = try BitwardenFixtures.vectorStretchedKey()
        let a = try EncString.encrypt("same plaintext", key: key)
        let b = try EncString.encrypt("same plaintext", key: key)
        XCTAssertNotEqual(a.iv, b.iv)
        XCTAssertNotEqual(a.ciphertext, b.ciphertext)
    }

    func testTamperedMACIsRejected() throws {
        let key = try BitwardenFixtures.vectorStretchedKey()
        let sealed = try EncString.encrypt("transfer 100 to andy", key: key)
        var mac = try XCTUnwrap(sealed.mac)
        mac[0] ^= 0x01
        let tampered = EncString(
            type: .aesCbc256_HmacSha256_B64,
            iv: sealed.iv,
            ciphertext: sealed.ciphertext,
            mac: mac)

        XCTAssertThrowsError(try tampered.decrypt(key: key)) { error in
            guard case VaultError.crypto(let detail) = error else {
                return XCTFail("expected a crypto error, got \(error)")
            }
            XCTAssertTrue(detail.contains("authentication check"), detail)
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        let key = try BitwardenFixtures.vectorStretchedKey()
        let sealed = try EncString.encrypt("transfer 100 to andy", key: key)
        var ciphertext = sealed.ciphertext
        ciphertext[0] ^= 0x80
        let tampered = EncString(
            type: .aesCbc256_HmacSha256_B64,
            iv: sealed.iv,
            ciphertext: ciphertext,
            mac: sealed.mac)

        // The MAC covers iv || ciphertext, so this must fail authentication —
        // it must NOT reach the cipher and fail on padding, which is the
        // padding-oracle shape we are avoiding.
        XCTAssertThrowsError(try tampered.decrypt(key: key)) { error in
            guard case VaultError.crypto(let detail) = error else {
                return XCTFail("expected a crypto error, got \(error)")
            }
            XCTAssertTrue(detail.contains("authentication check"), detail)
            XCTAssertFalse(
                detail.contains("padding"),
                "authentication must fail before decryption: \(detail)")
        }
    }

    func testTamperedIVIsRejected() throws {
        let key = try BitwardenFixtures.vectorStretchedKey()
        let sealed = try EncString.encrypt("transfer 100 to andy", key: key)
        var iv = sealed.iv
        iv[0] ^= 0x40
        let tampered = EncString(
            type: .aesCbc256_HmacSha256_B64,
            iv: iv,
            ciphertext: sealed.ciphertext,
            mac: sealed.mac)
        XCTAssertThrowsError(try tampered.decrypt(key: key))
    }

    func testWrongKeyIsRejected() throws {
        let key = try BitwardenFixtures.vectorStretchedKey()
        let other = try BitwardenFixtures.userKey()
        let sealed = try EncString.encrypt("secret", key: key)
        XCTAssertThrowsError(try sealed.decrypt(key: other))
    }

    func testTypeZeroIsRejectedByName() throws {
        let key = try BitwardenFixtures.vectorStretchedKey()
        // Same bytes as the recorded fixture, relabelled as the MAC-less type.
        let legacy = try EncString.parse(
            "0.AAECAwQFBgcICQoLDA0ODw==|jTy7gpypFURKBlYUcqNcVmyyv75FJVem2Nyjk6BpYKU=")
        XCTAssertEqual(legacy.type, .aesCbc256_B64)
        XCTAssertThrowsError(try legacy.decrypt(key: key)) { error in
            guard case VaultError.crypto(let detail) = error else {
                return XCTFail("expected a crypto error, got \(error)")
            }
            XCTAssertTrue(detail.contains("type 0"), detail)
            XCTAssertTrue(detail.contains("AES-256-CBC without a MAC"), detail)
        }
    }

    func testTypeSixIsRejectedByName() throws {
        let key = try BitwardenFixtures.vectorStretchedKey()
        let rsa = try EncString.parse(
            "6.AAECAwQFBgcICQoLDA0ODw==|jTy7gpypFURKBlYUcqNcVmyyv75FJVem2Nyjk6BpYKU="
                + "|yHl5XIMSOJRsTrkw57LOESNsklwC2J1ehqYgJoR6/5g=")
        XCTAssertEqual(rsa.type, .rsa2048_OaepSha1_HmacSha256_B64)
        XCTAssertThrowsError(try rsa.decrypt(key: key)) { error in
            guard case VaultError.crypto(let detail) = error else {
                return XCTFail("expected a crypto error, got \(error)")
            }
            XCTAssertTrue(detail.contains("type 6"), detail)
            XCTAssertTrue(detail.contains("RSA-2048"), detail)
        }
    }

    func testStructurallyInvalidStringsAreNil() {
        XCTAssertNil(EncString(""))
        XCTAssertNil(EncString("not an encstring"))
        XCTAssertNil(EncString("2."))
        XCTAssertNil(EncString("2.onlyonepart"))
        XCTAssertNil(EncString("2.a|b|c|d"))
        XCTAssertNil(EncString("99.AAECAwQFBgcICQoLDA0ODw==|AA==|AA=="))
        XCTAssertNil(EncString("2.!!!notbase64!!!|AA==|AA=="))
    }

    func testParseErrorNamesTheField() {
        XCTAssertThrowsError(try EncString.parse("garbage", field: "one-time code")) { error in
            XCTAssertTrue("\(error)".contains("one-time code"), "\(error)")
        }
    }

    func testShortMACIsRejected() throws {
        let key = try BitwardenFixtures.vectorStretchedKey()
        let sealed = try EncString.encrypt("x", key: key)
        let truncated = EncString(
            type: .aesCbc256_HmacSha256_B64,
            iv: sealed.iv,
            ciphertext: sealed.ciphertext,
            mac: sealed.mac?.prefix(16))
        XCTAssertThrowsError(try truncated.decrypt(key: key)) { error in
            XCTAssertTrue("\(error)".contains("HMAC tag"), "\(error)")
        }
    }

    // MARK: User key

    func testUnwrapUserKeyFromTheRecordedAccount() throws {
        let masterKey = try BitwardenCrypto.masterKey(
            password: "test",
            email: "test@bitwarden.com",
            kdf: .pbkdf2(iterations: BitwardenFixtures.liveKDFIterations)
        )
        let userKey = try BitwardenCrypto.unwrapUserKey(
            protectedKey: BitwardenFixtures.protectedUserKey,
            stretchedMasterKey: BitwardenCrypto.stretch(masterKey: masterKey)
        )
        XCTAssertEqual(
            userKey.concatenated.base64EncodedString(), BitwardenFixtures.userKeyBase64)
    }

    func testUnwrapWithTheWrongPasswordFails() throws {
        let masterKey = try BitwardenCrypto.masterKey(
            password: "not the password",
            email: "test@bitwarden.com",
            kdf: .pbkdf2(iterations: BitwardenFixtures.liveKDFIterations)
        )
        // Fails on the MAC, not on the padding: with the wrong key we never
        // reach the cipher at all.
        XCTAssertThrowsError(
            try BitwardenCrypto.unwrapUserKey(
                protectedKey: BitwardenFixtures.protectedUserKey,
                stretchedMasterKey: BitwardenCrypto.stretch(masterKey: masterKey)
            )
        ) { error in
            guard case VaultError.crypto(let detail) = error else {
                return XCTFail("expected a crypto error, got \(error)")
            }
            XCTAssertTrue(detail.contains("authentication check"), detail)
        }
    }

    func testUnwrapRejectsAKeyOfTheWrongLength() throws {
        let key = try BitwardenFixtures.vectorStretchedKey()
        // 32 bytes where 64 are required: the shape of a half-written key, and
        // the error has to say so rather than fail later at AES time.
        let sealed = try EncString.encrypt(Data(repeating: 7, count: 32), key: key)
        XCTAssertThrowsError(
            try BitwardenCrypto.unwrapUserKey(
                protectedKey: sealed.description, stretchedMasterKey: key)
        ) { error in
            XCTAssertTrue("\(error)".contains("64 bytes"), "\(error)")
        }
    }
}
