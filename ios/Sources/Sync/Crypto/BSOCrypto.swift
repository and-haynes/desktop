//  BSOCrypto.swift
//  The Sync 1.5 encrypted-payload format.
//
//  A BSO's `payload` is itself a JSON string holding three fields:
//
//      { "ciphertext": <base64>, "IV": <base64>, "hmac": <hex> }
//
//  The ciphertext is AES-256-CBC. The HMAC is SHA-256 **over the base64 text
//  of the ciphertext**, not over its bytes — an odd choice, but changing it
//  would mean not speaking Sync. The MAC is verified *before* decrypting, so a
//  tampered record never reaches the CBC implementation; doing it the other way
//  round is the classic padding-oracle.

import CryptoKit
import Foundation

/// The three fields of an encrypted payload. `IV` is capitalised because the
/// wire format capitalises it.
struct EncryptedPayload: Codable, Equatable, Sendable {
    var ciphertext: String
    var IV: String
    var hmac: String
}

enum BSOCrypto {

    enum Failure: Error, Equatable {
        case malformedPayload
        case hmacMismatch
        case notUTF8
    }

    static func encrypt(_ plaintext: Data, with bundle: SyncKeyBundle, iv: Data? = nil) throws
        -> EncryptedPayload
    {
        let iv = iv ?? AESCBC.randomIV()
        let ciphertext = try AESCBC.encrypt(
            plaintext, key: bundle.encryptionKey, iv: iv)
        let ciphertextBase64 = ciphertext.base64EncodedString()
        return EncryptedPayload(
            ciphertext: ciphertextBase64,
            IV: iv.base64EncodedString(),
            hmac: mac(forCiphertextBase64: ciphertextBase64, hmacKey: bundle.hmacKey).hexString)
    }

    static func decrypt(_ payload: EncryptedPayload, with bundle: SyncKeyBundle) throws -> Data {
        guard let ciphertext = Data(base64Encoded: payload.ciphertext),
            let iv = Data(base64Encoded: payload.IV),
            let expected = Data(hexString: payload.hmac.lowercased())
        else { throw Failure.malformedPayload }

        let actual = mac(forCiphertextBase64: payload.ciphertext, hmacKey: bundle.hmacKey)
        guard actual.constantTimeEquals(expected) else { throw Failure.hmacMismatch }

        return try AESCBC.decrypt(ciphertext, key: bundle.encryptionKey, iv: iv)
    }

    static func encryptJSON(_ value: JSONValue, with bundle: SyncKeyBundle, iv: Data? = nil) throws
        -> EncryptedPayload
    {
        try encrypt(value.serializedData(), with: bundle, iv: iv)
    }

    static func decryptJSON(_ payload: EncryptedPayload, with bundle: SyncKeyBundle) throws
        -> JSONValue
    {
        let data = try decrypt(payload, with: bundle)
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notUTF8 }
        return try JSONValue(jsonString: text)
    }

    /// HMAC-SHA256 over the *base64 characters* of the ciphertext.
    static func mac(forCiphertextBase64 base64: String, hmacKey: Data) -> Data {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: Data(base64.utf8), using: SymmetricKey(data: hmacKey)))
    }
}
