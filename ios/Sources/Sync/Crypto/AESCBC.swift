//  AESCBC.swift
//  AES-256-CBC with PKCS#7, via CommonCrypto.
//
//  CryptoKit deliberately offers no CBC: it is a footgun without a MAC, and
//  Apple would rather you used AES-GCM. Sync 1.5's record format predates that
//  advice and is CBC-then-HMAC, so this is the one place the older API is
//  necessary. It is not exposed outside `BSOCrypto`, which always applies the
//  MAC.

import CommonCrypto
import Foundation

enum AESCBC {

    enum Failure: Error, Equatable {
        case badKeySize
        case badIVSize
        /// CommonCrypto status code — almost always `kCCDecodeError`, i.e. a
        /// wrong key or corrupt ciphertext detected by the PKCS#7 padding.
        case cryptoFailed(Int32)
    }

    static let blockSize = kCCBlockSizeAES128

    static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(plaintext, key: key, iv: iv, operation: CCOperation(kCCEncrypt))
    }

    static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(ciphertext, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(_ input: Data, key: Data, iv: Data, operation: CCOperation) throws
        -> Data
    {
        guard key.count == kCCKeySizeAES256 else { throw Failure.badKeySize }
        guard iv.count == blockSize else { throw Failure.badIVSize }

        // CCCrypt may emit up to one extra block for PKCS#7 padding.
        let capacity = input.count + blockSize
        var output = Data(count: capacity)
        var written = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outBuffer in
            input.withUnsafeBytes { inBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress, key.count,
                            ivBuffer.baseAddress,
                            inBuffer.baseAddress, input.count,
                            outBuffer.baseAddress, capacity,
                            &written)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw Failure.cryptoFailed(status) }
        return output.prefix(written)
    }

    static func randomIV() -> Data { Data.randomBytes(blockSize) }
}

extension Data {
    /// Cryptographically secure random bytes. `SecRandomCopyBytes` cannot
    /// fail for a sane count, but it can *report* failure, and silently
    /// returning predictable bytes would be the worst possible response — so
    /// fall back to CryptoKit's generator rather than to zeros.
    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess {
            return Data(bytes)
        }
        return Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}
