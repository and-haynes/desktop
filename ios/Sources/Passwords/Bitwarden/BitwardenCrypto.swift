//  BitwardenCrypto.swift
//  Bitwarden's client-side crypto: master key, key stretching, and the
//  `EncString` wire format every field in a vault is wrapped in (#008AD).
//
//  Ported from the Ghostty iOS app's vault sync, which speaks the same
//  protocol to the same homelab Vaultwarden. Two things changed on the way
//  across, and both are load-bearing:
//
//  1. Ghostty imports swift-crypto (`import Crypto`) because its SSH stack
//     needs swift-nio-ssh's key types. Zen has **no external dependencies at
//     all**, so this uses CryptoKit. The primitives used here — `SHA256`,
//     `HMAC<SHA256>`, `SymmetricKey` — are spelled identically in both, so
//     the change is the import line and nothing else.
//  2. Ghostty carries its own AES-CBC over CommonCrypto. Zen already has one
//     in `Sources/Sync/Crypto/AESCBC.swift`, written for Sync 1.5's
//     CBC-then-HMAC records, and a second implementation of the same
//     primitive is a second place to get padding wrong. This calls that one
//     and translates its `Failure` into a `VaultError`. PBKDF2 is still
//     hand-rolled over CommonCrypto below, because neither CryptoKit nor
//     anything else in the app has it.
//
//  Key stretching goes through Zen's own `HKDF` (RFC 5869, checked against
//  the RFC's vectors in `SyncCryptoTests`) rather than CryptoKit's
//  `HKDF<SHA256>`. That is not merely taste: `enum HKDF` at module scope
//  shadows CryptoKit's generic of the same name inside this target, so
//  `HKDF<SHA256>.expand` would not even resolve here.
//
//  Nothing in this file talks to the network or knows what a login is. It is
//  the part that has to be exactly right, so it is the part that is pinned
//  against published vectors in `BitwardenCryptoTests`.

import CommonCrypto
import CryptoKit
import Foundation

// MARK: - KDF

/// How a Bitwarden account turns a master password into a master key.
///
/// The numbers come from the server's unauthenticated `prelogin` response and
/// are per-account, not per-server: an account created years ago may still be
/// on 100 000 PBKDF2 iterations while the server's default is 600 000. Never
/// assume a default — ask, then use what you are told.
enum BitwardenKDF: Equatable, Codable, Sendable {
    case pbkdf2(iterations: Int)
    case argon2id(iterations: Int, memoryMiB: Int, parallelism: Int)

    /// The `kdf` discriminator as the server reports it.
    var typeCode: Int {
        switch self {
        case .pbkdf2: return 0
        case .argon2id: return 1
        }
    }

    /// Human sentence for error messages and the connect screen.
    var summary: String {
        switch self {
        case .pbkdf2(let iterations):
            return "PBKDF2-SHA256, \(iterations) iterations"
        case .argon2id(let iterations, let memoryMiB, let parallelism):
            return "Argon2id, \(iterations) passes, \(memoryMiB) MiB, parallelism "
                + "\(parallelism)"
        }
    }
}

// MARK: - Argon2 seam

/// The Argon2id primitive, injected rather than imported.
///
/// CryptoKit has no Argon2 and Zen ships no third-party packages, so the
/// KDF-type-1 path is built against a protocol with a "not in this build"
/// default. Everything above this seam — salt derivation, stretching,
/// EncString — is already correct for Argon2 accounts; only the primitive is
/// missing, and the seam exists so that stays true.
protocol Argon2Hashing: Sendable {
    /// - Parameters:
    ///   - memoryKiB: Argon2's memory cost in **kibibytes**. Bitwarden reports
    ///     MiB, so callers multiply by 1024 — getting this wrong by a factor of
    ///     1024 produces a wrong key with no error.
    func hash(
        password: Data,
        salt: Data,
        iterations: Int,
        memoryKiB: Int,
        parallelism: Int,
        outputByteCount: Int
    ) throws -> Data
}

/// The default: refuse, clearly, rather than silently deriving a wrong key.
///
/// A wrong master key does not fail locally — it fails as a 400 from the
/// server's login endpoint, which looks exactly like a mistyped password. An
/// honest "this build cannot do Argon2id" is far more actionable.
struct Argon2Unavailable: Argon2Hashing {
    init() {}

    func hash(
        password: Data,
        salt: Data,
        iterations: Int,
        memoryKiB: Int,
        parallelism: Int,
        outputByteCount: Int
    ) throws -> Data {
        // TODO(#008AD): wire an Argon2 implementation if an account needs it.
        //
        // Zen's whole premise is zero external dependencies, so the honest
        // options are (a) vendor a public-domain Argon2 in C under Sources/,
        // or (b) keep refusing. The homelab's Vaultwarden uses KDF type 0
        // (PBKDF2, 600 000 iterations), so nothing is blocked on this today
        // and (b) stays the right trade until an account actually needs it.
        throw VaultError.crypto(
            """
            Argon2id is not available in this build, so this account's master key cannot be \
            derived. The account uses Argon2id (KDF type 1); only PBKDF2 (type 0) is supported \
            right now. Either switch the account to PBKDF2 in the Bitwarden web vault under \
            Security ▸ Keys, or use a build with Argon2 support.
            """
        )
    }
}

// MARK: - Symmetric key pair

/// Bitwarden's symmetric key: 32 bytes of AES key followed by 32 bytes of
/// HMAC key, always handled as a pair.
///
/// Two distinct keys, not one reused for both jobs — that is what makes the
/// encrypt-then-MAC construction below sound.
struct BitwardenSymmetricKey: Equatable {
    let encKey: SymmetricKey
    let macKey: SymmetricKey

    static let byteCount = 64
    static let halfByteCount = 32

    init(encKey: SymmetricKey, macKey: SymmetricKey) {
        self.encKey = encKey
        self.macKey = macKey
    }

    /// Split a 64-byte buffer into its enc and mac halves.
    init(concatenated data: Data) throws {
        guard data.count == Self.byteCount else {
            throw VaultError.crypto(
                "A Bitwarden symmetric key must be \(Self.byteCount) bytes; got \(data.count). "
                    + "This usually means the account's protected key decrypted with the wrong "
                    + "master password."
            )
        }
        // `Data` slices keep their parent's indices, so re-base before
        // splitting; `prefix`/`suffix` on a sliced Data is a classic
        // off-by-everything bug.
        let bytes = Data(data)
        self.encKey = SymmetricKey(data: bytes[0..<Self.halfByteCount])
        self.macKey = SymmetricKey(data: bytes[Self.halfByteCount..<Self.byteCount])
    }

    /// The 64-byte form, for persisting the unwrapped user key.
    var concatenated: Data {
        encKey.rawData + macKey.rawData
    }
}

extension SymmetricKey {
    /// `SymmetricKey` hides its bytes behind `withUnsafeBytes`; CommonCrypto
    /// needs them as `Data`.
    var rawData: Data {
        withUnsafeBytes { Data($0) }
    }
}

// MARK: - EncString

/// Bitwarden's `EncString` wire format.
///
/// A string of the form `<type>.<base64 iv>|<base64 ciphertext>|<base64 mac>`.
/// Only type 2 (AES-256-CBC + HMAC-SHA256, encrypt-then-MAC) is produced or
/// consumed here; the RSA types only ever wrap organisation keys, which this
/// provider does not touch.
struct EncString: Equatable, CustomStringConvertible {
    /// Bitwarden's `EncryptionType` enum, kept whole so an unsupported value
    /// can be *named* in the error rather than reported as "not type 2".
    enum EncryptionType: Int, Equatable {
        case aesCbc256_B64 = 0
        case aesCbc128_HmacSha256_B64 = 1
        case aesCbc256_HmacSha256_B64 = 2
        case rsa2048_OaepSha256_B64 = 3
        case rsa2048_OaepSha1_B64 = 4
        case rsa2048_OaepSha256_HmacSha256_B64 = 5
        case rsa2048_OaepSha1_HmacSha256_B64 = 6
        case xChaCha20Poly1305_B64 = 7

        var label: String {
            switch self {
            case .aesCbc256_B64: return "AES-256-CBC without a MAC"
            case .aesCbc128_HmacSha256_B64: return "AES-128-CBC + HMAC-SHA256"
            case .aesCbc256_HmacSha256_B64: return "AES-256-CBC + HMAC-SHA256"
            case .rsa2048_OaepSha256_B64: return "RSA-2048 OAEP-SHA256"
            case .rsa2048_OaepSha1_B64: return "RSA-2048 OAEP-SHA1"
            case .rsa2048_OaepSha256_HmacSha256_B64:
                return "RSA-2048 OAEP-SHA256 + HMAC-SHA256"
            case .rsa2048_OaepSha1_HmacSha256_B64:
                return "RSA-2048 OAEP-SHA1 + HMAC-SHA256"
            case .xChaCha20Poly1305_B64: return "XChaCha20-Poly1305"
            }
        }
    }

    /// The only type this provider writes, and the only one it can read.
    static let supportedType: EncryptionType = .aesCbc256_HmacSha256_B64

    let type: EncryptionType
    let iv: Data
    let ciphertext: Data
    /// nil for the MAC-less types; type 2 always has one.
    let mac: Data?

    private static let ivByteCount = 16
    private static let macByteCount = 32

    // MARK: Parsing

    /// Parse the wire form. Returns nil only when the string is not an
    /// EncString *at all*; an EncString of an unsupported type parses fine and
    /// fails at `decrypt`, so the error can name the type.
    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Split on the FIRST "." only: base64 never contains ".", but being
        // explicit costs nothing and documents the grammar.
        guard let dot = trimmed.firstIndex(of: ".") else { return nil }
        guard let rawType = Int(trimmed[trimmed.startIndex..<dot]),
            let type = EncryptionType(rawValue: rawType)
        else { return nil }

        let body = trimmed[trimmed.index(after: dot)...]
        let parts = body.split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        guard let iv = Data(base64Encoded: parts[0]),
            let ciphertext = Data(base64Encoded: parts[1])
        else { return nil }

        var mac: Data?
        if parts.count == 3 {
            guard let decoded = Data(base64Encoded: parts[2]) else { return nil }
            mac = decoded
        }

        self.type = type
        self.iv = iv
        self.ciphertext = ciphertext
        self.mac = mac
    }

    init(type: EncryptionType, iv: Data, ciphertext: Data, mac: Data?) {
        self.type = type
        self.iv = iv
        self.ciphertext = ciphertext
        self.mac = mac
    }

    /// Throwing companion to `init?`, for call sites that want a sentence to
    /// show someone instead of an optional.
    static func parse(_ string: String, field: String = "value") throws -> EncString {
        guard let parsed = EncString(string) else {
            throw VaultError.crypto(
                "The \(field) is not a Bitwarden encrypted string. Expected "
                    + "\"2.<iv>|<ciphertext>|<mac>\" in base64."
            )
        }
        return parsed
    }

    var description: String {
        let body = [
            iv.base64EncodedString(),
            ciphertext.base64EncodedString(),
            mac?.base64EncodedString(),
        ].compactMap { $0 }.joined(separator: "|")
        return "\(type.rawValue).\(body)"
    }

    // MARK: Decrypt

    func decrypt(key: BitwardenSymmetricKey) throws -> Data {
        guard type == Self.supportedType else {
            throw VaultError.crypto(
                "This item uses encryption type \(type.rawValue) (\(type.label)), which Zen "
                    + "cannot read. Only type \(Self.supportedType.rawValue) "
                    + "(\(Self.supportedType.label)) is supported."
            )
        }
        guard let mac else {
            throw VaultError.crypto(
                "A type 2 encrypted string must carry an HMAC, and this one has none."
            )
        }
        guard iv.count == Self.ivByteCount else {
            throw VaultError.crypto(
                "The initialisation vector is \(iv.count) bytes; AES-CBC needs "
                    + "\(Self.ivByteCount)."
            )
        }
        guard mac.count == Self.macByteCount else {
            throw VaultError.crypto(
                "The HMAC tag is \(mac.count) bytes; HMAC-SHA256 produces "
                    + "\(Self.macByteCount)."
            )
        }
        guard !ciphertext.isEmpty, ciphertext.count % AESCBC.blockSize == 0 else {
            throw VaultError.crypto(
                "The ciphertext is \(ciphertext.count) bytes, which is not a whole number of "
                    + "AES blocks. The item is corrupt."
            )
        }

        // Encrypt-then-MAC: authenticate BEFORE touching the cipher. Decrypting
        // first and checking afterwards is a padding oracle, and CBC padding
        // oracles are not theoretical.
        //
        // `isValidAuthenticationCode` is constant-time; `==` on Data is not.
        let authenticated = iv + ciphertext
        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                mac,
                authenticating: authenticated,
                using: key.macKey)
        else {
            throw VaultError.crypto(
                "This item failed its authentication check. Either the wrong key was used to "
                    + "open it, or it was modified in transit."
            )
        }

        return try BitwardenCrypto.decryptCBC(ciphertext, key: key.encKey.rawData, iv: iv)
    }

    /// Decrypt and interpret as UTF-8, which every Bitwarden string field is.
    func decryptToString(key: BitwardenSymmetricKey, field: String = "value") throws -> String {
        let data = try decrypt(key: key)
        guard let string = String(data: data, encoding: .utf8) else {
            throw VaultError.crypto(
                "The \(field) decrypted to bytes that are not valid UTF-8.")
        }
        return string
    }

    // MARK: Encrypt

    static func encrypt(_ data: Data, key: BitwardenSymmetricKey) throws -> EncString {
        // A fresh random IV per message. CBC with a reused IV leaks whether two
        // plaintexts share a prefix, and a password manager re-encrypts the
        // same username on every edit, so this matters in practice rather than
        // in theory. `AESCBC.randomIV` already refuses to fall back to zeros.
        let iv = AESCBC.randomIV()
        let ciphertext = try BitwardenCrypto.encryptCBC(
            data, key: key.encKey.rawData, iv: iv)
        let mac = HMAC<SHA256>.authenticationCode(for: iv + ciphertext, using: key.macKey)
        return EncString(
            type: supportedType,
            iv: iv,
            ciphertext: ciphertext,
            mac: Data(mac)
        )
    }

    static func encrypt(_ string: String, key: BitwardenSymmetricKey) throws -> EncString {
        try encrypt(Data(string.utf8), key: key)
    }
}

// MARK: - Crypto primitives

enum BitwardenCrypto {

    // MARK: Master key

    /// Derive the 32-byte master key from the master password.
    ///
    /// The salt is the account's *email*, normalised the way the Bitwarden
    /// clients normalise it (trimmed, lowercased) — except under Argon2id,
    /// where the salt is the **SHA-256 digest of that email** rather than the
    /// email itself. That asymmetry is real, undocumented in the obvious
    /// places, and produces a silently wrong key if you miss it: nothing fails
    /// locally, the server just rejects the login as a bad password.
    static func masterKey(
        password: String,
        email: String,
        kdf: BitwardenKDF,
        argon2: Argon2Hashing = Argon2Unavailable()
    ) throws -> SymmetricKey {
        let normalisedEmail = normalise(email: email)
        guard !normalisedEmail.isEmpty else {
            throw VaultError.crypto("The account email is empty, and it is the KDF salt.")
        }
        let passwordData = Data(password.utf8)

        switch kdf {
        case .pbkdf2(let iterations):
            return SymmetricKey(
                data: try pbkdf2SHA256(
                    password: passwordData,
                    salt: Data(normalisedEmail.utf8),
                    iterations: iterations,
                    keyByteCount: BitwardenSymmetricKey.halfByteCount
                ))

        case .argon2id(let iterations, let memoryMiB, let parallelism):
            let salt = Data(SHA256.hash(data: Data(normalisedEmail.utf8)))
            let derived = try argon2.hash(
                password: passwordData,
                salt: salt,
                iterations: iterations,
                memoryKiB: memoryMiB * 1024,
                parallelism: parallelism,
                outputByteCount: BitwardenSymmetricKey.halfByteCount
            )
            guard derived.count == BitwardenSymmetricKey.halfByteCount else {
                throw VaultError.crypto(
                    "The Argon2id implementation returned \(derived.count) bytes; expected "
                        + "\(BitwardenSymmetricKey.halfByteCount)."
                )
            }
            return SymmetricKey(data: derived)
        }
    }

    /// The value sent to the server as `password` in the token request.
    ///
    /// One more PBKDF2 round with the arguments swapped: the master key is the
    /// password, the master password is the salt, one iteration. The server
    /// never sees the master key, and the one iteration is fine because the
    /// input is already a 256-bit KDF output rather than a human password. The
    /// server applies its own slow hash on top before storing it.
    static func masterPasswordHash(masterKey: SymmetricKey, password: String) throws -> String {
        let hash = try pbkdf2SHA256(
            password: masterKey.rawData,
            salt: Data(password.utf8),
            iterations: 1,
            keyByteCount: BitwardenSymmetricKey.halfByteCount
        )
        return hash.base64EncodedString()
    }

    /// Bitwarden lowercases and trims the email before using it as a salt, so
    /// "Andy@Example.com " and "andy@example.com" reach the same vault.
    static func normalise(email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Key stretching

    /// Stretch the 32-byte master key into a 64-byte enc+mac pair.
    ///
    /// HKDF **expand only**, no extract step: the master key is already a
    /// uniformly random PRK straight out of a KDF, so extracting again would
    /// be wasted work — and, more to the point, would not match what every
    /// other Bitwarden client computes.
    ///
    /// `HKDF` here is Zen's own (`Sources/Sync/Crypto/HKDF.swift`), whose
    /// `expand` is RFC 5869 §2.3 and is checked against the RFC's vectors.
    static func stretch(masterKey: SymmetricKey) -> BitwardenSymmetricKey {
        let encKey = HKDF.expand(
            pseudoRandomKey: masterKey.rawData,
            info: Data("enc".utf8),
            length: BitwardenSymmetricKey.halfByteCount
        )
        let macKey = HKDF.expand(
            pseudoRandomKey: masterKey.rawData,
            info: Data("mac".utf8),
            length: BitwardenSymmetricKey.halfByteCount
        )
        return BitwardenSymmetricKey(
            encKey: SymmetricKey(data: encKey),
            macKey: SymmetricKey(data: macKey)
        )
    }

    /// Unwrap the account's user key from its protected form.
    ///
    /// The user key is what every cipher in the vault is actually encrypted
    /// with. It is stored on the server wrapped in an EncString that only the
    /// stretched master key opens — which is why changing the master password
    /// re-wraps one 64-byte blob instead of re-encrypting the whole vault.
    static func unwrapUserKey(
        protectedKey: String,
        stretchedMasterKey: BitwardenSymmetricKey
    ) throws -> BitwardenSymmetricKey {
        let encString = try EncString.parse(protectedKey, field: "account key")
        let raw = try encString.decrypt(key: stretchedMasterKey)
        return try BitwardenSymmetricKey(concatenated: raw)
    }

    // MARK: PBKDF2

    /// PBKDF2-HMAC-SHA256 via CommonCrypto.
    ///
    /// The one primitive Zen did not already have: CryptoKit ships no PBKDF2,
    /// deliberately, and Bitwarden's KDF is not negotiable.
    ///
    /// Empty password and empty salt are rejected rather than special-cased:
    /// CommonCrypto returns `kCCParamError` for a NULL input, Bitwarden
    /// requires both to be non-empty, and a bespoke workaround here would be
    /// untested code on a path that cannot occur.
    static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int,
        keyByteCount: Int
    ) throws -> Data {
        guard iterations > 0 else {
            throw VaultError.crypto(
                "The KDF iteration count must be at least 1, not \(iterations).")
        }
        guard iterations <= UInt32.max else {
            throw VaultError.crypto(
                "The KDF iteration count \(iterations) is implausibly large.")
        }
        guard !password.isEmpty else {
            throw VaultError.crypto("The master password is empty.")
        }
        guard !salt.isEmpty else {
            throw VaultError.crypto("The KDF salt is empty.")
        }
        guard keyByteCount > 0 else {
            throw VaultError.crypto("A derived key of \(keyByteCount) bytes was requested.")
        }

        var derived = Data(count: keyByteCount)
        let status: Int32 = derived.withUnsafeMutableBytes { outBuffer in
            guard let out = outBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(kCCParamError)
            }
            return password.withUnsafeBytes { passwordBuffer -> Int32 in
                guard
                    let passwordBytes = passwordBuffer.baseAddress?
                        .assumingMemoryBound(to: CChar.self)
                else { return Int32(kCCParamError) }
                return salt.withUnsafeBytes { saltBuffer -> Int32 in
                    guard
                        let saltBytes = saltBuffer.baseAddress?
                            .assumingMemoryBound(to: UInt8.self)
                    else { return Int32(kCCParamError) }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes,
                        password.count,
                        saltBytes,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        out,
                        keyByteCount
                    )
                }
            }
        }

        guard status == Int32(kCCSuccess) else {
            throw VaultError.crypto("PBKDF2 failed (CommonCrypto status \(status)).")
        }
        return derived
    }

    // MARK: AES-256-CBC, borrowed from the sync stack

    /// `AESCBC` throws its own `Failure`; everything above this file speaks
    /// `VaultError`. Translating here — rather than letting a
    /// `Failure.cryptoFailed(-4304)` reach the panel — is the difference
    /// between "the item is corrupt" and a number nobody can act on.
    static func encryptCBC(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        do {
            return try AESCBC.encrypt(plaintext, key: key, iv: iv)
        } catch let failure as AESCBC.Failure {
            throw translate(failure, operation: "encrypt")
        }
    }

    static func decryptCBC(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        do {
            return try AESCBC.decrypt(ciphertext, key: key, iv: iv)
        } catch let failure as AESCBC.Failure {
            throw translate(failure, operation: "decrypt")
        }
    }

    private static func translate(_ failure: AESCBC.Failure, operation: String) -> VaultError {
        switch failure {
        case .badKeySize:
            return .crypto("An AES-256 key must be 32 bytes.")
        case .badIVSize:
            return .crypto("An AES-CBC IV must be 16 bytes.")
        case .cryptoFailed(let status) where status == Int32(kCCDecodeError):
            // Only reachable on decrypt, and only after the MAC has already
            // verified — so this means genuine corruption, not an attack.
            return .crypto("The decrypted data has invalid PKCS#7 padding. The item is corrupt.")
        case .cryptoFailed(let status):
            return .crypto("AES-CBC \(operation) failed (CommonCrypto status \(status)).")
        }
    }
}
