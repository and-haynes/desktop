//  CertificateSheet.swift
//  Two prompts for one problem, because it is not the same problem.
//
//  A homelab box with a self-signed certificate is not a security incident —
//  it is Tuesday. Showing the owner a red interstitial for their own NAS
//  teaches them to click through red interstitials, which is exactly the habit
//  that gets people phished later. So the LAN case is calm and specific, and
//  the public case stays stern and does not offer to remember anything.

import SwiftUI

struct CertificateSheet: View {
    @ObservedObject var challenge: PendingCertificateChallenge
    @Environment(\.zenPalette) private var palette
    let onTrust: () -> Void
    let onReject: () -> Void

    /// The calm treatment is earned, not assumed: local host, a failure shape
    /// that a self-signed certificate actually produces, and no certificate
    /// change on a host we had already approved.
    private var friendly: Bool {
        challenge.isLocalNetwork && challenge.failure.isHomelabTypical
            && !challenge.certificateChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            card
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.dialogBackground.color.ignoresSafeArea())
        .presentationDetents([.height(friendly ? 400 : 460)])
        // The challenge must be answered exactly once. An interactive dismiss
        // would leave the load hanging forever with no error, so the only exits
        // are the two buttons.
        .interactiveDismissDisabled(true)
    }

    private var card: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(accent)

            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            fingerprint

            VStack(spacing: 6) {
                if friendly {
                    primaryButton("Trust \(challenge.host)", tint: accent, action: onTrust)
                    secondaryButton("Not now", action: onReject)
                } else {
                    // When we are not sure, the safe choice is the prominent one.
                    primaryButton("Back to safety", tint: accent, action: onReject)
                    secondaryButton("Proceed anyway", action: onTrust)
                }
            }
            .padding(.top, 2)
        }
        .padding(22)
    }

    /// Small, but present — it is the only way to check the certificate against
    /// the box itself (`openssl x509 -fingerprint -sha256` prints the same).
    private var fingerprint: some View {
        VStack(spacing: 3) {
            Text("SHA-256")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(
                TrustedCertificate(host: challenge.host, fingerprint: challenge.fingerprint)
                    .displayFingerprint
            )
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
    }

    // MARK: Copy

    private var icon: String {
        if challenge.certificateChanged { return "exclamationmark.shield" }
        return friendly ? "house.and.flag" : "exclamationmark.triangle.fill"
    }

    private var accent: Color {
        friendly ? palette.accent.color : Color(red: 0.84, green: 0.19, blue: 0.24)
    }

    private var title: String {
        if challenge.certificateChanged { return "\(challenge.host)'s certificate changed" }
        if friendly { return "\(challenge.host) uses its own certificate" }
        return "This connection is not private"
    }

    private var message: String {
        if challenge.certificateChanged {
            return """
                You trusted a different certificate for this address before. That \
                happens when a device is reinstalled — but it is also what someone \
                intercepting the connection would look like.
                """
        }
        if friendly {
            return "This is normal for devices on your home network. "
                + challenge.failure.explanation
        }
        return "\(challenge.host) could not prove it is who it says it is. "
            + "Someone may be interfering with the connection."
    }

    // MARK: Buttons

    private func primaryButton(_ label: String, tint: Color, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint))
        }
        .buttonStyle(ZenPressStyle(pressedScale: 0.98))
    }

    private func secondaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
        }
        .buttonStyle(ZenPressStyle(pressedScale: 0.98))
    }
}

/// Settings list of approved LAN certificates, with swipe-to-forget.
struct TrustedCertificatesView: View {
    @ObservedObject var store: TrustedCertificateStore

    var body: some View {
        List {
            if store.certificates.isEmpty {
                ContentUnavailableView(
                    "No trusted certificates",
                    systemImage: "checkmark.shield",
                    description: Text(
                        "Certificates you approve for devices on your home network appear here."
                    ))
            }
            ForEach(store.certificates) { certificate in
                VStack(alignment: .leading, spacing: 3) {
                    Text(certificate.host)
                        .font(.system(size: 15, weight: .medium))
                    Text(certificate.displayFingerprint)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("Trusted \(certificate.approvedAt, style: .date)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .swipeActions {
                    Button(role: .destructive) {
                        store.forget(certificate)
                    } label: {
                        Label("Forget", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("LAN Certificates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.certificates.isEmpty {
                Button("Forget All", role: .destructive) { store.forgetAll() }
            }
        }
    }
}
