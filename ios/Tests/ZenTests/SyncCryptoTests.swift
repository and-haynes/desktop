//  SyncCryptoTests.swift
//  The parts of Firefox Sync that are pure maths, checked against published
//  vectors rather than against ourselves.
//
//  Provenance of each vector is stated at its test, because a round-trip test
//  that only agrees with its own implementation proves nothing about
//  interoperating with Firefox.

import CryptoKit
import XCTest

@testable import Zen

final class HKDFTests: XCTestCase {

    /// RFC 5869 Appendix A.1 — "Basic test case with SHA-256".
    func testRFC5869TestCase1() {
        let ikm = Data(repeating: 0x0b, count: 22)
        let salt = Data(hexString: "000102030405060708090a0b0c")!
        let info = Data(hexString: "f0f1f2f3f4f5f6f7f8f9")!

        let prk = HKDF.extract(salt: salt, inputKeyMaterial: ikm)
        XCTAssertEqual(
            prk.hexString,
            "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")

        let okm = HKDF.expand(pseudoRandomKey: prk, info: info, length: 42)
        XCTAssertEqual(
            okm.hexString,
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
                + "34007208d5b887185865")
    }

    /// RFC 5869 Appendix A.2 — longer inputs and outputs, which is what
    /// exercises the expand loop's counter past a single block.
    func testRFC5869TestCase2() {
        let ikm = Data((0x00...0x4f).map(UInt8.init))
        let salt = Data((0x60...0xaf).map(UInt8.init))
        let info = Data((0xb0...0xff).map(UInt8.init))

        let prk = HKDF.extract(salt: salt, inputKeyMaterial: ikm)
        XCTAssertEqual(
            prk.hexString,
            "06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244")

        let okm = HKDF.expand(pseudoRandomKey: prk, info: info, length: 82)
        XCTAssertEqual(
            okm.hexString,
            "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c"
                + "59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71"
                + "cc30c58179ec3e87c14c01d5c1f3434f1d87")
    }

    /// RFC 5869 Appendix A.3 — zero-length salt and info. This is the shape
    /// Sync's own derivation uses, so it matters that the "no salt" path is
    /// the RFC's and not an improvisation.
    func testRFC5869TestCase3() {
        let ikm = Data(repeating: 0x0b, count: 22)

        let prk = HKDF.extract(salt: Data(), inputKeyMaterial: ikm)
        XCTAssertEqual(
            prk.hexString,
            "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04")

        let okm = HKDF.derive(inputKeyMaterial: ikm, info: Data(), length: 42)
        XCTAssertEqual(
            okm.hexString,
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d"
                + "9d201395faa4b61a96c8")
    }

    /// An empty salt and a 32-byte zero salt have to agree, because HMAC
    /// zero-pads short keys to its block size. Sync relies on this: the
    /// documented derivation says "no salt", and implementations differ on
    /// which of the two they write.
    func testEmptySaltEqualsZeroSalt() {
        let ikm = Data(repeating: 0x5a, count: 32)
        XCTAssertEqual(
            HKDF.derive(inputKeyMaterial: ikm, salt: Data(), info: "x", length: 64),
            HKDF.derive(
                inputKeyMaterial: ikm, salt: Data(repeating: 0, count: 32), info: "x",
                length: 64))
    }
}

final class SyncKeyBundleTests: XCTestCase {

    /// The info string is the one place a typo produces a plausible-looking
    /// bundle that decrypts nothing. `picl`, not `fxa`.
    func testOldSyncInfoString() {
        XCTAssertEqual(SyncKeyBundle.oldSyncKeyInfo, "identity.mozilla.com/picl/v1/oldsync")
        XCTAssertEqual(SyncKeyBundle.oldSyncScope, "https://identity.mozilla.com/apps/oldsync")
    }

    /// Derivation from kB is HKDF with the documented info string and no salt,
    /// split 32/32. Checked against an independent HKDF run rather than
    /// against `SyncKeyBundle` itself.
    func testDeriveFromKB() throws {
        let kB = Data(hexString: String(repeating: "ab", count: 32))!
        let bundle = try XCTUnwrap(SyncKeyBundle.oldSync(fromKB: kB))

        let expected = HKDF.derive(
            inputKeyMaterial: kB, salt: Data(),
            info: "identity.mozilla.com/picl/v1/oldsync", length: 64)
        XCTAssertEqual(bundle.encryptionKey, expected.prefix(32))
        XCTAssertEqual(bundle.hmacKey, expected.suffix(32))
        XCTAssertNotEqual(bundle.encryptionKey, bundle.hmacKey)
    }

    func testRejectsWrongSizedKeyMaterial() {
        XCTAssertNil(SyncKeyBundle(keyMaterial: Data(repeating: 1, count: 63)))
        XCTAssertNil(SyncKeyBundle(keyMaterial: Data(repeating: 1, count: 65)))
        XCTAssertNotNil(SyncKeyBundle(keyMaterial: Data(repeating: 1, count: 64)))
    }

    func testBase64PairRoundTrip() throws {
        let bundle = try XCTUnwrap(SyncKeyBundle(keyMaterial: Data.randomBytes(64)))
        XCTAssertEqual(SyncKeyBundle(base64Pair: bundle.base64Pair), bundle)
        XCTAssertNil(SyncKeyBundle(base64Pair: ["not base64 at all!!", "nor this"]))
    }

    /// The `kid` FxA issues is `<rotation timestamp>-<fingerprint>`; the
    /// fingerprint half is base64url over the first 16 bytes of SHA-256.
    func testFingerprintShape() {
        let material = Data(repeating: 0x11, count: 64)
        let fingerprint = SyncKeyBundle.fingerprint(ofKeyMaterial: material)
        XCTAssertEqual(
            fingerprint,
            Data(SHA256.hash(data: material).prefix(16)).base64URLString)
        XCTAssertEqual(Base64URL.decode(fingerprint)?.count, 16)
    }
}

final class BSOCryptoTests: XCTestCase {

    /// AES-256-CBC + HMAC-SHA256 interop vector.
    ///
    /// Generated with OpenSSL 3 (`openssl enc -aes-256-cbc -K … -iv … -nopad`
    /// over PKCS#7-padded plaintext) and Python's `hmac`, *not* taken from
    /// Mozilla's published record — so what it proves is that our payload
    /// format agrees with a standard implementation byte for byte: PKCS#7
    /// padding, the HMAC taken over the base64 *text* of the ciphertext, and
    /// lowercase hex for the MAC. Those three are where a home-grown Sync
    /// client goes wrong.
    private static let vectorKeys = "xxqny9i4Ko/27aVcOUef0scap8vYuCqP9u2lXDlHn9I="
    private static let vectorHMACKey = "fcbdDqp6dbZ7Sj5rDy1NP33G3Q6qenW2e0o+aw8tTT8="
    private static let vectorIV = "sLCwsLCwsLCwsLCwsLCwsA=="
    private static let vectorCiphertext = "L0OTdGJvbCgZrdkA78w6cimOLaUONqShxglp+dPvd5o="
    private static let vectorHMAC =
        "2479270af4834d51fd0294eb72203cdc07993bc80c8fbac657d6ef775da0f48c"
    private static let vectorPlaintext = #"{"id":"space-1","kind":"space"}"#

    private func vectorBundle() throws -> SyncKeyBundle {
        try XCTUnwrap(SyncKeyBundle(base64Pair: [Self.vectorKeys, Self.vectorHMACKey]))
    }

    func testDecryptsOpenSSLVector() throws {
        let payload = EncryptedPayload(
            ciphertext: Self.vectorCiphertext, IV: Self.vectorIV, hmac: Self.vectorHMAC)
        let plaintext = try BSOCrypto.decrypt(payload, with: vectorBundle())
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), Self.vectorPlaintext)
    }

    func testEncryptReproducesOpenSSLVector() throws {
        let payload = try BSOCrypto.encrypt(
            Data(Self.vectorPlaintext.utf8), with: vectorBundle(),
            iv: Data(base64Encoded: Self.vectorIV)!)
        XCTAssertEqual(payload.ciphertext, Self.vectorCiphertext)
        XCTAssertEqual(payload.hmac, Self.vectorHMAC)
        XCTAssertEqual(payload.IV, Self.vectorIV)
    }

    func testHMACIsOverTheBase64Text() throws {
        let bundle = try vectorBundle()
        let overText = BSOCrypto.mac(
            forCiphertextBase64: Self.vectorCiphertext, hmacKey: bundle.hmacKey)
        XCTAssertEqual(overText.hexString, Self.vectorHMAC)

        // The same HMAC over the decoded bytes is a different value; a client
        // that gets this backwards fails only against other clients.
        let raw = Data(base64Encoded: Self.vectorCiphertext)!
        let overBytes = Data(
            HMAC<SHA256>.authenticationCode(
                for: raw, using: SymmetricKey(data: bundle.hmacKey)))
        XCTAssertNotEqual(overBytes.hexString, Self.vectorHMAC)
    }

    func testTamperedCiphertextFailsHMACBeforeDecrypting() throws {
        var payload = EncryptedPayload(
            ciphertext: Self.vectorCiphertext, IV: Self.vectorIV, hmac: Self.vectorHMAC)
        var bytes = Data(base64Encoded: payload.ciphertext)!
        bytes[0] ^= 0xff
        payload.ciphertext = bytes.base64EncodedString()

        XCTAssertThrowsError(try BSOCrypto.decrypt(payload, with: vectorBundle())) { error in
            XCTAssertEqual(error as? BSOCrypto.Failure, .hmacMismatch)
        }
    }

    func testWrongKeyIsRejected() throws {
        let payload = EncryptedPayload(
            ciphertext: Self.vectorCiphertext, IV: Self.vectorIV, hmac: Self.vectorHMAC)
        let wrong = try XCTUnwrap(SyncKeyBundle(keyMaterial: Data(repeating: 9, count: 64)))
        XCTAssertThrowsError(try BSOCrypto.decrypt(payload, with: wrong))
    }

    func testUppercaseHMACIsAccepted() throws {
        let payload = EncryptedPayload(
            ciphertext: Self.vectorCiphertext, IV: Self.vectorIV,
            hmac: Self.vectorHMAC.uppercased())
        XCTAssertNoThrow(try BSOCrypto.decrypt(payload, with: vectorBundle()))
    }

    func testJSONRoundTripWithRandomKeysAndIVs() throws {
        let bundle = try XCTUnwrap(SyncKeyBundle(keyMaterial: Data.randomBytes(64)))
        let record = JSONValue.object([
            "id": .string("abcdefghijkl"),
            "kind": .string("space"),
            "data": .object([
                "name": .string("Wörk — 日本語 \"quoted\""),
                "children": .array([.string("a"), .string("b")]),
                "theme": .null,
            ]),
        ])
        for _ in 0..<8 {
            let payload = try BSOCrypto.encryptJSON(record, with: bundle)
            XCTAssertEqual(try BSOCrypto.decryptJSON(payload, with: bundle), record)
        }
    }

    /// A payload whose plaintext is exactly a block long still needs a full
    /// block of PKCS#7 padding — the classic off-by-one-block bug.
    func testBlockAlignedPlaintext() throws {
        let bundle = try XCTUnwrap(SyncKeyBundle(keyMaterial: Data.randomBytes(64)))
        let plaintext = Data(repeating: 0x41, count: 32)
        let payload = try BSOCrypto.encrypt(plaintext, with: bundle)
        XCTAssertEqual(Data(base64Encoded: payload.ciphertext)?.count, 48)
        XCTAssertEqual(try BSOCrypto.decrypt(payload, with: bundle), plaintext)
    }
}

final class HawkTests: XCTestCase {

    /// The canonical vector from the Hawk specification's README
    /// (hueniverse/hawk, "Protocol Example"): a GET with `ext` and no payload.
    func testPublishedHeaderVector() {
        let credentials = HawkCredentials(
            id: "dh37fgj492je", key: "werxhqb98rpaxn39848xrunpaw3489ruxnpa98w4rxn")
        let url = URL(string: "http://example.com:8000/resource/1?b=1&a=2")!

        XCTAssertEqual(
            Hawk.normalisedRequestString(
                timestamp: 1_353_832_234, nonce: "j4h3g2", method: "GET",
                requestURI: "/resource/1?b=1&a=2", host: "example.com", port: 8000,
                payloadHash: "", ext: "some-app-ext-data"),
            "hawk.1.header\n1353832234\nj4h3g2\nGET\n/resource/1?b=1&a=2\n"
                + "example.com\n8000\n\nsome-app-ext-data\n")

        let header = Hawk.authorizationHeader(
            credentials: credentials, method: "GET", url: url,
            timestamp: 1_353_832_234, nonce: "j4h3g2", ext: "some-app-ext-data")
        XCTAssertEqual(
            header,
            "Hawk id=\"dh37fgj492je\", ts=\"1353832234\", nonce=\"j4h3g2\", "
                + "ext=\"some-app-ext-data\", mac=\"6R4rV5iE+NPoym+WwjeHzjAGXUtLNIxmo1vpMofpLAE=\""
        )
    }

    /// The payload-hash vector from the same document.
    func testPublishedPayloadHashVector() {
        XCTAssertEqual(
            Hawk.payloadHash(
                Data("Thank you for flying Hawk".utf8), contentType: "text/plain"),
            "Yi9LfIIFRtBEPt74PVmbTF/xVAwPn7ub15ePICfgnuY=")
    }

    /// Content-type parameters are not signed, so `text/plain; charset=utf-8`
    /// and `text/plain` must hash identically — otherwise a proxy that
    /// normalises the header breaks every POST.
    func testPayloadHashIgnoresContentTypeParameters() {
        let body = Data("Thank you for flying Hawk".utf8)
        XCTAssertEqual(
            Hawk.payloadHash(body, contentType: "text/plain; charset=utf-8"),
            Hawk.payloadHash(body, contentType: "TEXT/PLAIN"))
    }

    /// Hawk signs path-and-query, and the default port for the scheme when the
    /// URL does not spell one out.
    func testRequestURIAndDefaultPorts() {
        XCTAssertEqual(
            Hawk.requestURI(for: URL(string: "https://sync.example/1.5/42/storage/spaces?full=1")!),
            "/1.5/42/storage/spaces?full=1")
        XCTAssertEqual(Hawk.requestURI(for: URL(string: "https://sync.example")!), "/")
        XCTAssertEqual(Hawk.defaultPort(forScheme: "https"), 443)
        XCTAssertEqual(Hawk.defaultPort(forScheme: "http"), 80)
    }

    /// A POST carries `hash=` in the header; a GET must not.
    func testPayloadRequestsIncludeHash() {
        let credentials = HawkCredentials(id: "id", key: "key")
        let url = URL(string: "https://sync.example/1.5/42/storage/spaces")!
        let post = Hawk.authorizationHeader(
            credentials: credentials, method: "POST", url: url,
            payload: Data("[]".utf8), contentType: "application/json",
            timestamp: 1, nonce: "n")
        XCTAssertTrue(post.contains("hash=\""))

        let get = Hawk.authorizationHeader(
            credentials: credentials, method: "GET", url: url, timestamp: 1, nonce: "n")
        XCTAssertFalse(get.contains("hash=\""))
        XCTAssertFalse(get.contains("ext=\""))
    }
}

final class ScopedKeyJWETests: XCTestCase {

    /// The whole scoped-key delivery, end to end, with a key pair generated
    /// here: seal a keys_jwe to our ephemeral public key exactly as FxA does,
    /// then decrypt it and split the result into a sync key bundle.
    func testScopedKeyRoundTrip() throws {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let material = Data.randomBytes(64)
        let kid = "1697059200000-" + SyncKeyBundle.fingerprint(ofKeyMaterial: material)

        let body = JSONValue.object([
            SyncKeyBundle.oldSyncScope: .object([
                "kty": .string("oct"),
                "scope": .string(SyncKeyBundle.oldSyncScope),
                "k": .string(material.base64URLString),
                "kid": .string(kid),
            ])
        ])
        let jwe = try ScopedKeyJWE.encrypt(
            body.serializedData(), to: ephemeral.publicKey)

        let plaintext = try ScopedKeyJWE.decrypt(jwe, with: ephemeral)
        let key = try XCTUnwrap(
            ScopedKeyJWE.scopedKey(SyncKeyBundle.oldSyncScope, fromPlaintext: plaintext))

        XCTAssertEqual(key.keyMaterial, material)
        XCTAssertEqual(key.kid, kid)
        let bundle = try XCTUnwrap(key.keyBundle)
        XCTAssertEqual(bundle.encryptionKey, material.prefix(32))
        XCTAssertEqual(bundle.hmacKey, material.suffix(32))
    }

    func testWrongRecipientKeyFails() throws {
        let ours = P256.KeyAgreement.PrivateKey()
        let theirs = P256.KeyAgreement.PrivateKey()
        let jwe = try ScopedKeyJWE.encrypt(Data("{}".utf8), to: ours.publicKey)
        XCTAssertThrowsError(try ScopedKeyJWE.decrypt(jwe, with: theirs)) { error in
            XCTAssertEqual(error as? ScopedKeyJWE.Failure, .decryptionFailed)
        }
    }

    /// The protected header is the AEAD's additional data, so editing it —
    /// even in a field we ignore — invalidates the tag.
    func testTamperedHeaderFails() throws {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let jwe = try ScopedKeyJWE.encrypt(Data("{}".utf8), to: ephemeral.publicKey)
        var parts = jwe.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        var header = try JSONValue(jsonData: Base64URL.decode(parts[0])!)
        header["apu"] = .string("aW5qZWN0ZWQ")
        parts[0] = try header.serializedData().base64URLString

        XCTAssertThrowsError(
            try ScopedKeyJWE.decrypt(parts.joined(separator: "."), with: ephemeral))
    }

    func testRejectsUnsupportedAlgorithms() throws {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let header = JSONValue.object([
            "alg": .string("RSA-OAEP"), "enc": .string("A256GCM"),
        ])
        let serialization = [
            try header.serializedData().base64URLString, "", "AAAA", "AAAA", "AAAA",
        ].joined(separator: ".")
        XCTAssertThrowsError(try ScopedKeyJWE.decrypt(serialization, with: ephemeral)) {
            XCTAssertEqual(
                $0 as? ScopedKeyJWE.Failure, .unsupportedAlgorithm("RSA-OAEP"))
        }
    }

    func testMalformedCompactSerialization() throws {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try ScopedKeyJWE.decrypt("only.three.parts", with: ephemeral)) {
            XCTAssertEqual($0 as? ScopedKeyJWE.Failure, .malformedCompactSerialization)
        }
    }

    /// A JWK's `x` and `y` are fixed-width 32-byte base64url, and the point has
    /// to survive the trip back into CryptoKit.
    func testJWKRoundTrip() throws {
        let key = P256.KeyAgreement.PrivateKey().publicKey
        let jwk = ScopedKeyJWE.jwk(for: key)
        XCTAssertEqual(jwk["kty"]?.stringValue, "EC")
        XCTAssertEqual(jwk["crv"]?.stringValue, "P-256")
        XCTAssertEqual(Base64URL.decode(jwk["x"]!.stringValue!)?.count, 32)
        XCTAssertEqual(Base64URL.decode(jwk["y"]!.stringValue!)?.count, 32)
        XCTAssertEqual(try ScopedKeyJWE.publicKey(fromJWK: jwk).rawRepresentation,
                       key.rawRepresentation)
    }

    /// RFC 7518 §4.6.2's Concat KDF: one SHA-256 round for a 256-bit key, and
    /// the counter/SuppPubInfo framing means a different `enc` gives a
    /// different content-encryption key.
    func testConcatKDFIsDeterministicAndAlgorithmBound() {
        let z = Data(repeating: 0x2a, count: 32)
        let a = ScopedKeyJWE.concatKDF(
            sharedSecret: z, algorithmID: "A256GCM", partyUInfo: Data(), partyVInfo: Data(),
            keyDataLengthBits: 256)
        let b = ScopedKeyJWE.concatKDF(
            sharedSecret: z, algorithmID: "A256GCM", partyUInfo: Data(), partyVInfo: Data(),
            keyDataLengthBits: 256)
        let other = ScopedKeyJWE.concatKDF(
            sharedSecret: z, algorithmID: "A128GCM", partyUInfo: Data(), partyVInfo: Data(),
            keyDataLengthBits: 256)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, other)
    }
}

final class PKCETests: XCTestCase {

    /// RFC 7636 Appendix B's worked example.
    func testRFC7636AppendixBVector() {
        let challenge = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(challenge.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(challenge.method, "S256")
    }

    func testGeneratedVerifierIsWithinTheAllowedLength() {
        for _ in 0..<32 {
            let challenge = PKCEChallenge()
            XCTAssertTrue((43...128).contains(challenge.verifier.count))
            XCTAssertEqual(challenge.challenge.count, 43)
            XCTAssertFalse(challenge.verifier.contains("="))
            XCTAssertFalse(challenge.verifier.contains("+"))
            XCTAssertFalse(challenge.verifier.contains("/"))
        }
    }
}

final class Base64URLTests: XCTestCase {

    func testRoundTripAndAlphabet() {
        for length in 0..<64 {
            let data = Data.randomBytes(length)
            let encoded = Base64URL.encode(data)
            XCTAssertFalse(encoded.contains("+"))
            XCTAssertFalse(encoded.contains("/"))
            XCTAssertFalse(encoded.contains("="))
            XCTAssertEqual(Base64URL.decode(encoded), data)
        }
    }

    /// Servers differ on padding; both forms have to decode.
    func testAcceptsPaddedInput() {
        XCTAssertEqual(Base64URL.decode("YQ=="), Data("a".utf8))
        XCTAssertEqual(Base64URL.decode("YQ"), Data("a".utf8))
    }

    func testHexRoundTrip() {
        let data = Data.randomBytes(37)
        XCTAssertEqual(Data(hexString: data.hexString), data)
        XCTAssertNil(Data(hexString: "abc"))
        XCTAssertNil(Data(hexString: "zz"))
    }

    func testConstantTimeEquals() {
        let a = Data.randomBytes(32)
        XCTAssertTrue(a.constantTimeEquals(a))
        var b = a
        b[31] ^= 1
        XCTAssertFalse(a.constantTimeEquals(b))
        XCTAssertFalse(a.constantTimeEquals(a.prefix(31)))
    }
}

final class JSONValueTests: XCTestCase {

    /// `canonicalJSON` has to match the desktop's: keys sorted recursively,
    /// so two structurally equal payloads produce one digest.
    func testCanonicalJSONSortsKeysRecursively() throws {
        let a = try JSONValue(jsonString: #"{"b":1,"a":{"d":[1,2],"c":null}}"#)
        let b = try JSONValue(jsonString: #"{"a":{"c":null,"d":[1,2]},"b":1}"#)
        XCTAssertEqual(a.canonicalJSON, #"{"a":{"c":null,"d":[1,2]},"b":1}"#)
        XCTAssertEqual(a.canonicalJSON, b.canonicalJSON)
        XCTAssertEqual(a.digest, b.digest)
    }

    func testDigestsDifferOnContent() throws {
        let a = try JSONValue(jsonString: #"{"name":"Work"}"#)
        let b = try JSONValue(jsonString: #"{"name":"Home"}"#)
        XCTAssertNotEqual(a.digest, b.digest)
    }

    /// Whole numbers must not canonicalise as `1.0` — the desktop's
    /// `JSON.stringify` writes `1`, and a digest mismatch means an endless
    /// re-upload loop rather than a visible failure.
    func testWholeNumbersCanonicaliseWithoutADecimalPoint() throws {
        let value = try JSONValue(jsonString: #"{"opacity":0.5,"texture":0,"count":12}"#)
        XCTAssertEqual(value.canonicalJSON, #"{"count":12,"opacity":0.5,"texture":0}"#)
    }

    func testPreservesUnknownBranches() throws {
        let source = #"{"c":[{"algorithm":"analogous","lightness":62,"weird":{"x":[]}}]}"#
        let value = try JSONValue(jsonString: source)
        XCTAssertEqual(try JSONValue(jsonString: value.serializedString()), value)
    }

    func testEscaping() {
        let value = JSONValue.string("line\nbreak \"quoted\" back\\slash\u{1}")
        XCTAssertEqual(
            value.canonicalJSON,
            "\"line\\nbreak \\\"quoted\\\" back\\\\slash\\u0001\"")
    }
}
