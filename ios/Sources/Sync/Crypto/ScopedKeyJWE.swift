//  ScopedKeyJWE.swift
//  ECDH-ES + A256GCM JWE, which is how FxA delivers scoped keys.
//
//  The client generates an ephemeral P-256 key pair and sends the public half
//  as `keys_jwk` on the authorization request. The token response then carries
//  `keys_jwe`: a compact JWE addressed to that key, whose plaintext is
//
//      { "<scope>": { "kty": "oct", "scope": …, "k": <base64url>, "kid": … } }
//
//  ECDH-ES in *direct* mode (there is no `alg` key wrapping), so the content
//  encryption key is the Concat-KDF output itself and the second compact
//  segment is empty. JOSE's Concat KDF is NIST SP 800-56A §5.8.1 with SHA-256
//  and a single round, since 256 bits out is exactly one hash.

import CryptoKit
import Foundation

enum ScopedKeyJWE {

    enum Failure: Error, Equatable {
        case malformedCompactSerialization
        case unsupportedAlgorithm(String)
        case missingEphemeralKey
        case badEphemeralKey
        case decryptionFailed
        case notUTF8
    }

    /// The pieces of a compact JWE, split out so the header can be inspected
    /// before any key agreement happens.
    struct Compact: Equatable {
        let protectedHeaderBase64: String
        let header: JSONValue
        let encryptedKey: Data
        let iv: Data
        let ciphertext: Data
        let tag: Data

        init(_ serialization: String) throws {
            let parts = serialization.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 5,
                let headerData = Base64URL.decode(String(parts[0])),
                let key = Base64URL.decode(String(parts[1])),
                let iv = Base64URL.decode(String(parts[2])),
                let ciphertext = Base64URL.decode(String(parts[3])),
                let tag = Base64URL.decode(String(parts[4]))
            else { throw Failure.malformedCompactSerialization }
            protectedHeaderBase64 = String(parts[0])
            header = (try? JSONValue(jsonData: headerData)) ?? .null
            encryptedKey = key
            self.iv = iv
            self.ciphertext = ciphertext
            self.tag = tag
        }
    }

    // MARK: Decryption

    /// Decrypt `keys_jwe` with the ephemeral private key whose public half was
    /// sent as `keys_jwk`, and return the raw plaintext JSON.
    static func decrypt(_ serialization: String, with privateKey: P256.KeyAgreement.PrivateKey)
        throws -> Data
    {
        let jwe = try Compact(serialization)

        let alg = jwe.header["alg"]?.stringValue ?? ""
        let enc = jwe.header["enc"]?.stringValue ?? ""
        guard alg == "ECDH-ES" else { throw Failure.unsupportedAlgorithm(alg) }
        guard enc == "A256GCM" else { throw Failure.unsupportedAlgorithm(enc) }

        guard let epk = jwe.header["epk"] else { throw Failure.missingEphemeralKey }
        let peer = try publicKey(fromJWK: epk)

        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let z = shared.withUnsafeBytes { Data($0) }

        let cek = concatKDF(
            sharedSecret: z,
            algorithmID: enc,
            partyUInfo: Base64URL.decode(jwe.header["apu"]?.stringValue ?? "") ?? Data(),
            partyVInfo: Base64URL.decode(jwe.header["apv"]?.stringValue ?? "") ?? Data(),
            keyDataLengthBits: 256)

        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: jwe.iv), ciphertext: jwe.ciphertext, tag: jwe.tag)
            return try AES.GCM.open(
                box, using: SymmetricKey(data: cek),
                authenticating: Data(jwe.protectedHeaderBase64.utf8))
        } catch {
            throw Failure.decryptionFailed
        }
    }

    /// Pull one scope's key material out of a decrypted `keys_jwe` body.
    static func scopedKey(_ scope: String, fromPlaintext data: Data) throws -> ScopedKey? {
        guard let object = try JSONValue(jsonData: data).objectValue,
            let entry = object[scope],
            let k = entry["k"]?.stringValue,
            let material = Base64URL.decode(k)
        else { return nil }
        return ScopedKey(
            scope: scope, keyMaterial: material,
            kid: entry["kid"]?.stringValue ?? "")
    }

    // MARK: Encryption (used by the round-trip test, and nowhere else)

    /// Seal `plaintext` to `recipient`, producing the same compact form FxA
    /// sends. Having both halves here is what makes the scoped-key path
    /// testable without an account.
    static func encrypt(
        _ plaintext: Data, to recipient: P256.KeyAgreement.PublicKey,
        ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()
    ) throws -> String {
        let header = JSONValue.object([
            "alg": .string("ECDH-ES"),
            "enc": .string("A256GCM"),
            "epk": jwk(for: ephemeral.publicKey),
        ])
        let headerBase64 = try header.serializedData().base64URLString

        let z = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
            .withUnsafeBytes { Data($0) }
        let cek = concatKDF(
            sharedSecret: z, algorithmID: "A256GCM", partyUInfo: Data(), partyVInfo: Data(),
            keyDataLengthBits: 256)

        let sealed = try AES.GCM.seal(
            plaintext, using: SymmetricKey(data: cek),
            nonce: AES.GCM.Nonce(data: Data.randomBytes(12)),
            authenticating: Data(headerBase64.utf8))

        return [
            headerBase64,
            "",
            Data(sealed.nonce).base64URLString,
            sealed.ciphertext.base64URLString,
            sealed.tag.base64URLString,
        ].joined(separator: ".")
    }

    // MARK: JWK

    /// The public half of the ephemeral key, in the shape `keys_jwk` wants.
    static func jwk(for key: P256.KeyAgreement.PublicKey) -> JSONValue {
        // x963Representation is 0x04 ‖ X ‖ Y for an uncompressed point.
        let raw = key.x963Representation.dropFirst()
        return .object([
            "kty": .string("EC"),
            "crv": .string("P-256"),
            "x": .string(Data(raw.prefix(32)).base64URLString),
            "y": .string(Data(raw.suffix(32)).base64URLString),
        ])
    }

    static func publicKey(fromJWK jwk: JSONValue) throws -> P256.KeyAgreement.PublicKey {
        guard let x = jwk["x"]?.stringValue.flatMap(Base64URL.decode),
            let y = jwk["y"]?.stringValue.flatMap(Base64URL.decode),
            x.count == 32, y.count == 32
        else { throw Failure.badEphemeralKey }
        var representation = Data([0x04])
        representation.append(x)
        representation.append(y)
        guard let key = try? P256.KeyAgreement.PublicKey(x963Representation: representation) else {
            throw Failure.badEphemeralKey
        }
        return key
    }

    // MARK: Concat KDF

    /// NIST SP 800-56A §5.8.1 as JOSE profiles it (RFC 7518 §4.6.2). Each of
    /// AlgorithmID, PartyUInfo and PartyVInfo is length-prefixed with a 32-bit
    /// big-endian byte count; SuppPubInfo is the key length in *bits*.
    static func concatKDF(
        sharedSecret z: Data, algorithmID: String, partyUInfo: Data, partyVInfo: Data,
        keyDataLengthBits: Int
    ) -> Data {
        let hashLengthBits = SHA256.byteCount * 8
        let rounds = Int(ceil(Double(keyDataLengthBits) / Double(hashLengthBits)))
        var output = Data()
        for counter in 1...max(rounds, 1) {
            var input = Data()
            input.append(bigEndian(UInt32(counter)))
            input.append(z)
            input.append(lengthPrefixed(Data(algorithmID.utf8)))
            input.append(lengthPrefixed(partyUInfo))
            input.append(lengthPrefixed(partyVInfo))
            input.append(bigEndian(UInt32(keyDataLengthBits)))
            output.append(Data(SHA256.hash(data: input)))
        }
        return output.prefix(keyDataLengthBits / 8)
    }

    private static func lengthPrefixed(_ data: Data) -> Data {
        var out = bigEndian(UInt32(data.count))
        out.append(data)
        return out
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

/// One scope's key as FxA delivers it: 64 bytes of material and the `kid`
/// that the token server expects back in `X-KeyID`.
struct ScopedKey: Equatable, Sendable, Codable {
    let scope: String
    let keyMaterial: Data
    let kid: String

    var keyBundle: SyncKeyBundle? { SyncKeyBundle(keyMaterial: keyMaterial) }
}
