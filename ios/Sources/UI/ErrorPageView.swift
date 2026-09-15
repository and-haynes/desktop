//  ErrorPageView.swift
//  What you see instead of a blank page (#0089A).
//
//  The failure this replaces showed nothing at all: no host, no reason, no
//  next step. Everything here exists to answer "what now?" — the other scheme,
//  the ports a homelab service is actually likely to be on, and, when the
//  address is on the local network, the permission that silently blocks it.

import SwiftUI
import UIKit

struct ErrorPageView: View {
    let failure: LoadFailure
    @Environment(\.zenPalette) private var palette
    let onRetry: () -> Void
    let onNavigate: (URL) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 40)

                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(palette.text.withAlpha(0.55).color)

                Text(failure.title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(palette.text.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(failure.message)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)

                Button(action: onRetry) {
                    Text("Retry")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: 260)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(palette.accent.color))
                }
                .buttonStyle(ZenPressStyle(pressedScale: 0.98))
                .accessibilityIdentifier("errorRetry")

                if !failure.suggestions().isEmpty {
                    suggestions
                }

                if failure.isLocalNetwork {
                    localNetworkHint
                }

                // Small, but the thing worth pasting into a search.
                Text("\(failure.url.absoluteString) · error \(failure.code)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.text.withAlpha(0.35).color)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.top, 4)

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .background(palette.mainBrowserBackground.color)
        .accessibilityIdentifier("errorPage")
    }

    private var symbol: String {
        switch failure.kind {
        case .secureConnectionFailed: return "lock.trianglebadge.exclamationmark"
        case .hostNotFound: return "questionmark.circle"
        case .noNetwork: return "wifi.exclamationmark"
        case .timedOut: return "clock.badge.exclamationmark"
        default: return "exclamationmark.triangle"
        }
    }

    private var suggestions: some View {
        VStack(spacing: 8) {
            Text(failure.usedDefaultPort ? "Try instead" : "Try instead")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.text.withAlpha(0.45).color)
            // A wrapping row: the scheme flip is wordy, the ports are short.
            FlowRow(spacing: 8) {
                ForEach(failure.suggestions()) { suggestion in
                    Button {
                        onNavigate(suggestion.url)
                    } label: {
                        Text(suggestion.label)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(palette.text.color)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background {
                                Capsule().fill(palette.toolbarElementHoverBG.color)
                            }
                            .overlay {
                                Capsule().strokeBorder(
                                    palette.borderContrast.color, lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(ZenPressStyle())
                    .accessibilityIdentifier("suggestion-\(suggestion.label)")
                }
            }
        }
        .padding(.top, 4)
    }

    /// On a real device the first connection to a LAN address triggers the
    /// Local Network prompt; if it was denied, every attempt afterwards fails
    /// with no visible cause at all.
    private var localNetworkHint: some View {
        VStack(spacing: 6) {
            Text("On a home network?")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.text.withAlpha(0.7).color)
            Text(
                "Zen needs Local Network access to reach devices in your home. "
                    + "If you declined the prompt, turn it on in Settings."
            )
            .font(.system(size: 12))
            .foregroundStyle(palette.textSecondary.color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Text("Open Settings")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(ZenPressStyle())
            .accessibilityIdentifier("openSettings")
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.toolbarElementHoverBG.color)
        }
        .padding(.top, 4)
    }
}

/// A minimal wrapping HStack. SwiftUI has no first-party flow layout below
/// iOS 16's `Layout`, and the suggestion chips need to wrap on a narrow phone.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
