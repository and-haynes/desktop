//  SyncKeyBundle.swift
//  The (encryption key, HMAC key) pair every Sync 1.5 payload is sealed with.
//
//  Two ways in, and both end at the same 64 bytes:
//
//  · **Scoped keys** (what we actually use). The `keys_jwe` an FxA OAuth
//    response carries holds, per requested scope, a JWK whose `k` is 64 bytes
//    of key material — Mozilla's servers have already run the derivation
//    below. Its `kid` is what the token server wants in `X-KeyID`.
//  · **From kB**, the account's class-B key, with HKDF and the documented
//    info string. This is the derivation the scoped-key service performs, and
//    keeping it here is what lets the two paths be checked against each other.
//
//  Either way the first 32 bytes are the AES-256 key and the last 32 the
//  HMAC-SHA256 key, and never the same 32 twice.

import CryptoKit
import Foundation

struct SyncKeyBundle: Equatable, Sendable {

    /// `https://identity.mozilla.com/apps/oldsync` — the OAuth scope whose
    /// scoped key is the sync key.
    static let oldSyncScope = "https://identity.mozilla.com/apps/oldsync"

    /// The HKDF info string Mozilla documents for deriving the oldsync key
    /// from kB. Note `picl` (the project's original name), not `fxa`.
    static let oldSyncKeyInfo = "identity.mozilla.com/picl/v1/oldsync"

    /// 32 bytes, AES-256-CBC.
    let encryptionKey: Data
    /// 32 bytes, HMAC-SHA256.
    let hmacKey: Data

    init?(encryptionKey: Data, hmacKey: Data) {
        guard encryptionKey.count == 32, hmacKey.count == 32 else { return nil }
        self.encryptionKey = encryptionKey
        self.hmacKey = hmacKey
    }

    /// Split the 64-byte block a scoped key (or `crypto/keys`) hands over.
    init?(keyMaterial: Data) {
        guard keyMaterial.count == 64 else { return nil }
        self.init(
            encryptionKey: keyMaterial.prefix(32),
            hmacKey: keyMaterial.suffix(32))
    }

    /// `crypto/keys` stores each half as its own standard-base64 string.
    init?(base64Pair pair: [String]) {
        guard pair.count == 2,
            let enc = Data(base64Encoded: pair[0]),
            let mac = Data(base64Encoded: pair[1])
        else { return nil }
        self.init(encryptionKey: enc, hmacKey: mac)
    }

    var base64Pair: [String] {
        [encryptionKey.base64EncodedString(), hmacKey.base64EncodedString()]
    }

    /// HKDF-SHA256(ikm: kB, salt: ∅, info: "identity.mozilla.com/picl/v1/oldsync", L: 64).
    static func oldSync(fromKB kB: Data) -> SyncKeyBundle? {
        SyncKeyBundle(
            keyMaterial: HKDF.derive(
                inputKeyMaterial: kB, info: oldSyncKeyInfo, length: 64))
    }

    /// The key-material half of a scoped key's `kid`: base64url of the first
    /// 16 bytes of SHA-256 over the 64-byte key. FxA prefixes it with the key
    /// rotation timestamp, so this is only half the `kid` — use the server's
    /// value when you have one, and this to check it.
    static func fingerprint(ofKeyMaterial material: Data) -> String {
        Data(SHA256.hash(data: material).prefix(16)).base64URLString
    }
}
