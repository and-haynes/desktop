//  SyncDiagnosticsView.swift
//  Settings → Sync → Sync diagnostics (#008AA).
//
//  The screen that answers "where did it stop?". It is deliberately reachable
//  when signed *out*, because that is exactly when a sign-in has just failed
//  and the transcript is the only evidence there is.

import SwiftUI
import UIKit

struct SyncDiagnosticsView: View {
    @ObservedObject var diagnostics: SyncDiagnostics
    @State private var didCopy = false

    var body: some View {
        Form {
            if diagnostics.entries.isEmpty {
                Section {
                    Text("Nothing recorded yet. Start a sign-in and the steps appear here.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(diagnostics.entries) { entry in
                        row(entry)
                    }
                } header: {
                    Text("Transcript")
                } footer: {
                    Text(
                        "Oldest first. The last line is where the flow got to — quote the "
                            + "whole thing on the ticket. No password, authorization code or "
                            + "token is ever written here; values that matter only by their "
                            + "presence are recorded by their length.")
                }

                Section {
                    Button {
                        UIPasteboard.general.string = diagnostics.transcript
                        didCopy = true
                        Haptics.shared.fire(.tabSelect)
                    } label: {
                        Label(
                            didCopy ? "Copied" : "Copy transcript",
                            systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("syncDiagnosticsCopyButton")

                    Button("Clear", role: .destructive) {
                        diagnostics.clear()
                        didCopy = false
                    }
                    .accessibilityIdentifier("syncDiagnosticsClearButton")
                }
            }
        }
        .navigationTitle("Sync diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("syncDiagnosticsView")
    }

    private func row(_ entry: SyncDiagnostics.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.symbol)
                .foregroundStyle(tint(entry.outcome))
                .font(.caption)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.step.rawValue)
                    .font(.callout)
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(entry.outcome == .failed ? Color.red : Color.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(entry.at, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private func tint(_ outcome: SyncDiagnostics.Outcome) -> Color {
        switch outcome {
        case .note: return .secondary
        case .ok: return .green
        case .failed: return .red
        }
    }
}

/// Presenting the alert is the caller's job, and it has to happen somewhere
/// with a presentation context — a `.alert` attached to a `Section` inside a
/// `Form` silently does nothing, the same trap the sign-in sheet fell into.
/// Kept as a modifier so the Settings body does not grow another two levels of
/// chain for the type checker to walk.
struct SyncFailureAlert: ViewModifier {
    @ObservedObject var diagnostics: SyncDiagnostics

    func body(content: Content) -> some View {
        content.alert(
            "Sync stopped at \(diagnostics.failure?.step.rawValue ?? "an unknown step")",
            isPresented: isPresented, presenting: diagnostics.failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { diagnostics.failure != nil },
            set: { if !$0 { diagnostics.failure = nil } })
    }
}

extension View {
    func syncFailureAlert(_ diagnostics: SyncDiagnostics) -> some View {
        modifier(SyncFailureAlert(diagnostics: diagnostics))
    }
}
