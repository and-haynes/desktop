//  PKCE.swift
//  RFC 7636 proof key for code exchange, S256.
//
//  A public client has no secret, so the authorization code is the only thing
//  standing between an attacker who can observe the redirect and the account.
//  PKCE binds the code to a verifier only this process has seen.

import CryptoKit
import Foundation

struct PKCEChallenge: Equatable, Sendable {
    let verifier: String
    let challenge: String
    let method = "S256"

    /// 32 random bytes → 43 base64url characters, comfortably inside RFC
    /// 7636's 43–128 range.
    init(verifier: String = Data.randomBytes(32).base64URLString) {
        self.verifier = verifier
        self.challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLString
    }
}
