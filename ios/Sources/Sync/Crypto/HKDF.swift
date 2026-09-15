//  HKDF.swift
//  HKDF-SHA256 (RFC 5869), extract-and-expand.
//
//  CryptoKit ships `HKDF<SHA256>`, but Sync's info strings and its
//  "no salt at all" convention are easier to state — and to check against the
//  RFC's own test vectors — with the two steps written out.

import CryptoKit
import Foundation

enum HKDF {

    /// RFC 5869 §2.2. An empty salt is the same as a 32-byte zero salt: HMAC
    /// zero-pads any key shorter than its block size, so the RFC's "if not
    /// provided, set to a string of HashLen zeros" needs no special case.
    static func extract(salt: Data, inputKeyMaterial ikm: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt)))
    }

    /// RFC 5869 §2.3.
    static func expand(pseudoRandomKey prk: Data, info: Data, length: Int) -> Data {
        precondition(length <= 255 * SHA256.byteCount, "HKDF: L must be at most 255 * HashLen")
        let key = SymmetricKey(data: prk)
        var output = Data()
        var block = Data()
        var counter: UInt8 = 1
        while output.count < length {
            var input = block
            input.append(info)
            input.append(counter)
            block = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
            output.append(block)
            counter &+= 1
        }
        return output.prefix(length)
    }

    static func derive(inputKeyMaterial ikm: Data, salt: Data = Data(), info: Data, length: Int)
        -> Data
    {
        expand(
            pseudoRandomKey: extract(salt: salt, inputKeyMaterial: ikm), info: info,
            length: length)
    }

    static func derive(inputKeyMaterial ikm: Data, salt: Data = Data(), info: String, length: Int)
        -> Data
    {
        derive(inputKeyMaterial: ikm, salt: salt, info: Data(info.utf8), length: length)
    }
}
