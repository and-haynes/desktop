//  TrustedCertificateStore.swift
//  Remembers which self-signed certificates the owner has approved.
//
//  Keyed on host *and* fingerprint, not host alone: a changed certificate on a
//  known host has to re-prompt, because that is exactly what a machine-in-the-
//  middle looks like. Re-keying on the fingerprint means approving 10.0.0.42
//  once does not blanket-approve whatever answers on that address later.

import Foundation
import CryptoKit

struct TrustedCertificate: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    /// Lowercased host exactly as it appeared in the challenge.
    var host: String
    /// Lowercase hex SHA-256 of the leaf certificate's DER bytes.
    var fingerprint: String
    var approvedAt: Date = Date()

    /// `AB:CD:EF:…`, which is how every other tool prints a fingerprint.
    var displayFingerprint: String {
        stride(from: 0, to: fingerprint.count, by: 2)
            .map { offset -> String in
                let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
                let end = fingerprint.index(start, offsetBy: 2, limitedBy: fingerprint.endIndex)
                    ?? fingerprint.endIndex
                return String(fingerprint[start..<end]).uppercased()
            }
            .joined(separator: ":")
    }
}

@MainActor
final class TrustedCertificateStore: ObservableObject {
    @Published private(set) var certificates: [TrustedCertificate] = []

    private let file: JSONFileStore<[TrustedCertificate]>

    init(file: JSONFileStore<[TrustedCertificate]>? = nil) {
        self.file = file ?? JSONFileStore<[TrustedCertificate]>(name: "trusted-certs.json")
        certificates = self.file.load() ?? []
    }

    /// What we know about this host, which decides which prompt to show.
    enum Verdict: Equatable {
        /// Approved before with this exact certificate — proceed silently.
        case trusted
        /// Never seen this host.
        case unknown
        /// Known host, different certificate. Say so prominently.
        case changed(previous: TrustedCertificate)
    }

    func verdict(host: String, fingerprint: String) -> Verdict {
        let host = host.lowercased()
        let fingerprint = fingerprint.lowercased()
        let forHost = certificates.filter { $0.host == host }
        if forHost.contains(where: { $0.fingerprint == fingerprint }) { return .trusted }
        if let previous = forHost.first { return .changed(previous: previous) }
        return .unknown
    }

    /// Approving a host replaces any earlier certificate for it — keeping both
    /// would mean a rotated-back certificate is silently accepted.
    func trust(host: String, fingerprint: String) {
        let host = host.lowercased()
        certificates.removeAll { $0.host == host }
        certificates.insert(
            TrustedCertificate(host: host, fingerprint: fingerprint.lowercased()), at: 0)
        persist()
    }

    func forget(_ certificate: TrustedCertificate) {
        certificates.removeAll { $0.id == certificate.id }
        persist()
    }

    func forgetAll() {
        certificates = []
        persist()
    }

    private func persist() {
        file.save(certificates)
    }
}

enum CertificateFingerprint {
    /// SHA-256 of the leaf certificate's DER encoding — the same number
    /// `openssl x509 -fingerprint -sha256` prints, so the owner can check it
    /// against the box itself.
    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
