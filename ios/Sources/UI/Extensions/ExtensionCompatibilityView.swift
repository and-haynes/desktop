//  ExtensionCompatibilityView.swift
//  The compatibility report, shown twice: once before installing and once
//  afterwards in Settings.
//
//  It is the same view both times deliberately. The install sheet is where
//  somebody decides, and Settings is where they come back three weeks later to
//  work out why a thing is not working — and "why is it not working" deserves
//  the same answer as "should I install this".

import SwiftUI

struct ExtensionCompatibilityView: View {
    let report: ExtensionCompatibilityReport
    @Environment(\.zenPalette) private var palette

    var body: some View {
        Section {
            if report.findings.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing unsupported found")
                        Text(scanNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                ForEach(report.findings) { finding in
                    FindingRow(finding: finding)
                }
            }
        } header: {
            Text("Compatibility")
        } footer: {
            Text(
                "This is a static check: Zen reads the manifest and looks for `browser.` and "
                    + "`chrome.` calls in the extension's scripts, then compares them with what "
                    + "WebKit implements. Minified code can hide a call, and a call behind a "
                    + "feature test is reported even though the extension copes with it. It is a "
                    + "warning, not a verdict — nothing here stops an install.")
        }
    }

    private var scanNote: String {
        let files = report.scannedFileCount
        let names = report.detectedNamespaces.count
        return
            "\(files) script\(files == 1 ? "" : "s") read, \(names) "
            + "API\(names == 1 ? "" : "s") seen — all of them supported."
    }

    struct FindingRow: View {
        let finding: ExtensionCompatibilityReport.Finding

        var body: some View {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(finding.subject)
                            .font(.system(.subheadline, design: .monospaced))
                        Spacer(minLength: 4)
                        Text(finding.severity.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(tint)
                    }
                    Text(finding.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !finding.locations.isEmpty {
                        Text(finding.locations.joined(separator: ", "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            } icon: {
                Image(systemName: finding.severity.symbol).foregroundStyle(tint)
            }
            .accessibilityIdentifier("compatFinding-\(finding.subject)")
        }

        private var tint: Color {
            switch finding.severity {
            case .blocking: return .red
            case .degraded: return .orange
            case .note: return .secondary
            }
        }
    }
}

/// The one-line version, for a list row.
struct ExtensionCompatibilityBadge: View {
    let report: ExtensionCompatibilityReport

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(report.summary)
        }
        .font(.caption)
        .foregroundStyle(tint)
    }

    private var symbol: String {
        report.worstSeverity?.symbol ?? "checkmark.circle"
    }

    private var tint: Color {
        switch report.worstSeverity {
        case .blocking: return .red
        case .degraded: return .orange
        case .note, .none: return .secondary
        }
    }
}
