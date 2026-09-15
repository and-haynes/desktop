//  CertificateChallenge.swift
//  The model behind the TLS trust prompt.
//
//  A server-trust challenge has to be answered exactly once — dropping the
//  completion handler hangs the load forever, calling it twice traps. The
//  handler therefore lives inside `PendingCertificateChallenge`, which can only
//  be answered once and complains in debug if it is deallocated unanswered.

import Foundation
import Security

/// Why the system refused the certificate. Only the homelab-shaped failures get
/// the friendly treatment.
struct TrustFailure: OptionSet, Sendable {
    let rawValue: Int

    static let selfSigned = TrustFailure(rawValue: 1 << 0)
    static let unknownAuthority = TrustFailure(rawValue: 1 << 1)
    static let hostnameMismatch = TrustFailure(rawValue: 1 << 2)
    static let expired = TrustFailure(rawValue: 1 << 3)
    /// Anything we did not recognise — revocation, weak key, policy failure.
    static let other = TrustFailure(rawValue: 1 << 4)

    /// The set a self-signed homelab certificate actually produces. Anything
    /// outside this is not "normal for your home network" and must not be
    /// dressed up as though it were.
    static let homelabTypical: TrustFailure = [
        .selfSigned, .unknownAuthority, .hostnameMismatch, .expired,
    ]

    var isHomelabTypical: Bool {
        !isEmpty && subtracting(.homelabTypical).isEmpty
    }

    var explanation: String {
        if contains(.hostnameMismatch) && contains(.expired) {
            return "Its certificate is out of date and made out to a different name."
        }
        if contains(.expired) { return "Its certificate is out of date." }
        if contains(.hostnameMismatch) {
            return "Its certificate is made out to a different name."
        }
        return "It signed its own certificate rather than buying one."
    }
}

/// A challenge waiting on the owner, carrying everything the sheet needs.
@MainActor
final class PendingCertificateChallenge: Identifiable, ObservableObject {
    let id = UUID()
    let host: String
    let fingerprint: String
    let failure: TrustFailure
    let isLocalNetwork: Bool
    let previousCertificate: TrustedCertificate?

    private var completion: ((Disposition) -> Void)?
    /// `deinit` is nonisolated and so cannot read the main-actor `completion`.
    /// This box carries the same fact somewhere the tripwire can see it; by the
    /// time deinit runs the last reference is gone, so there is no concurrent
    /// access to guard against.
    private final class AnsweredFlag: @unchecked Sendable { var value = false }
    private let answered = AnsweredFlag()

    enum Disposition {
        case trust
        case reject
    }

    init(
        host: String, fingerprint: String, failure: TrustFailure, isLocalNetwork: Bool,
        previousCertificate: TrustedCertificate?,
        completion: @escaping (Disposition) -> Void
    ) {
        self.host = host
        self.fingerprint = fingerprint
        self.failure = failure
        self.isLocalNetwork = isLocalNetwork
        self.previousCertificate = previousCertificate
        self.completion = completion
    }

    /// The certificate changed on a host we had already approved — the one case
    /// that deserves a warning even on the LAN.
    var certificateChanged: Bool { previousCertificate != nil }

    /// Answer the challenge. Safe to call more than once; only the first counts.
    func resolve(_ disposition: Disposition) {
        guard let completion else { return }
        self.completion = nil
        answered.value = true
        completion(disposition)
    }

    deinit {
        // A dropped handler is a page that spins forever with no error. If this
        // fires, some path tore the sheet down without answering.
        assert(answered.value, "certificate challenge for \(host) was never answered")
    }
}

enum ServerTrustEvaluator {
    /// Evaluate the trust and, on failure, classify why.
    /// Returns nil when the certificate is fine and the load should proceed.
    static func failureReason(for trust: SecTrust, host: String) -> TrustFailure? {
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return nil }

        guard let error = error as Error? as NSError? else { return .other }
        // Security reports the specific reason in the underlying OSStatus.
        let code = error.code
        var failure: TrustFailure = []

        switch code {
        case Int(errSecCertificateExpired), Int(errSecCertificateNotValidYet):
            failure.insert(.expired)
        case Int(errSecHostNameMismatch):
            failure.insert(.hostnameMismatch)
        case Int(errSecNotTrusted), Int(errSecTrustSettingDeny):
            failure.insert(.unknownAuthority)
        default:
            failure.insert(.other)
        }

        // The localized description is the only place the "self-signed" and
        // combined-reason detail surfaces, so mine it for the common phrases.
        let description = error.localizedDescription.lowercased()
        if description.contains("self-signed") || description.contains("self signed") {
            failure.insert(.selfSigned)
            failure.remove(.other)
        }
        if description.contains("not trusted") || description.contains("root") {
            failure.insert(.unknownAuthority)
            failure.remove(.other)
        }
        if description.contains("expired") {
            failure.insert(.expired)
            failure.remove(.other)
        }
        if description.contains("host") && description.contains("match") {
            failure.insert(.hostnameMismatch)
            failure.remove(.other)
        }
        return failure.isEmpty ? .other : failure
    }

    /// SHA-256 of the leaf certificate, or nil if the chain is empty.
    static func leafFingerprint(of trust: SecTrust) -> String? {
        let leaf: SecCertificate?
        if #available(iOS 15.0, *) {
            leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        } else {
            leaf = SecTrustGetCertificateAtIndex(trust, 0)
        }
        guard let leaf else { return nil }
        return CertificateFingerprint.sha256(of: SecCertificateCopyData(leaf) as Data)
    }
}
