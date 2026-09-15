//  SecurityDetailSheet.swift
//  What the URL pill's warning badge opens (#0089A).
//
//  Three things end up behind the same glyph, because from the outside they are
//  the same question — "why is there a triangle?" — and the answer differs:
//  a certificate you approved, a connection that is not encrypted at all, or a
//  page that never loaded.

import SwiftUI

struct SecurityDetailSheet: View {
    let detail: SecurityDetail
    @ObservedObject var state: BrowserState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette

    var body: some View {
        NavigationStack {
            Form {
                switch detail {
                case .trusted(let certificate): trusted(certificate)
                case .insecure(let host): insecure(host)
                case .failed(let failure): failed(failure)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(palette.accent.color)
    }

    private var title: String {
        switch detail {
        case .trusted: return "Certificate"
        case .insecure: return "Not Encrypted"
        case .failed: return "Didn't Load"
        }
    }

    // MARK: Trusted certificate

    @ViewBuilder
    private func trusted(_ certificate: TrustedCertificate) -> some View {
        Section {
            LabeledContent("Host", value: certificate.host)
            LabeledContent("Approved") {
                Text(certificate.approvedAt, format: .dateTime.day().month().year().hour().minute())
            }
        } header: {
            Text("Approved by you")
        } footer: {
            Text(
                "This host signed its own certificate and you accepted it. Zen remembers "
                    + "the certificate, not just the host — if it changes, you will be asked "
                    + "again.")
        }

        Section {
            Text(certificate.displayFingerprint)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        } header: {
            Text("SHA-256 fingerprint")
        } footer: {
            Text("Compare with `openssl x509 -fingerprint -sha256` on the machine itself.")
        }

        Section {
            Button(role: .destructive) {
                Haptics.shared.fire(.tabClose)
                state.trustedCertificates.forget(certificate)
                dismiss()
            } label: {
                Label("Forget this certificate", systemImage: "trash")
            }
        } footer: {
            Text("The next connection to \(certificate.host) will ask again.")
        }
    }

    // MARK: Plain HTTP

    @ViewBuilder
    private func insecure(_ host: String) -> some View {
        Section {
            LabeledContent("Host", value: host.isEmpty ? "this page" : host)
            LabeledContent("Protocol", value: "HTTP")
        } footer: {
            Text(
                "Nothing sent to or from this page is encrypted, and anything on the network "
                    + "between you and it can read or change it. That is normal for a box on "
                    + "your own network and worth avoiding anywhere else.")
        }

        if let tab = state.activeTab, let secure = httpsVariant(of: tab.url) {
            Section {
                Button {
                    Haptics.shared.fire(.urlCommit)
                    state.updateTab(tab.id) {
                        $0.url = secure
                        $0.loadFailure = nil
                        $0.title = ""
                    }
                    dismiss()
                } label: {
                    Label("Try https://\(host)", systemImage: "lock")
                }
            } footer: {
                Text("Many home services answer on HTTPS too, with a self-signed certificate.")
            }
        }
    }

    private func httpsVariant(of url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http" else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url
    }

    // MARK: A failed load

    @ViewBuilder
    private func failed(_ failure: LoadFailure) -> some View {
        Section {
            Text(failure.title)
                .font(.system(size: 16, weight: .semibold))
            Text(failure.message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }

        Section {
            LabeledContent("Address", value: failure.url.absoluteString)
            LabeledContent("Host", value: failure.host)
            LabeledContent("Port", value: String(failure.port))
            LabeledContent("Error", value: String(failure.code))
        } header: {
            Text("Details")
        } footer: {
            if failure.isLocalNetwork {
                Text(
                    "This is a local address. If Zen was denied Local Network access, every "
                        + "connection to it fails with no other sign — check iOS Settings.")
            }
        }

        Section {
            Button {
                Haptics.shared.fire(.urlCommit)
                NotificationCenter.default.post(name: .zenReloadActiveTab, object: nil)
                dismiss()
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
            }
        }
    }
}
