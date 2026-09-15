//  LocalNetworkView.swift
//  Settings › Local network: scan, pick, keep (#0089C).
//
//  Three things happen on this screen and they are deliberately in order:
//  find what is there, choose what is worth keeping, and — only then — decide
//  whether to trust its certificate. Trust is the last step and its own button,
//  never a side effect of importing, because approving a certificate is the one
//  decision here that has security consequences (#00889 makes the same point
//  from the other direction).

import SwiftUI

struct LocalNetworkView: View {
    @ObservedObject var state: BrowserState
    @StateObject private var scanner = LANScanController()
    @Environment(\.zenPalette) private var palette

    @State private var customPortText = ""
    @State private var includePrivileged = false
    @State private var selection: Set<String> = []
    @State private var trustReport: TrustReport?
    @State private var importedCount: Int?

    /// `url.absoluteString` per selected finding — stable across the list
    /// rebuilding itself as the scan fills in titles and certificates.
    private var store: LocalServiceStore { state.localServices }

    var body: some View {
        Form {
            scanSection
            if scanner.isScanning || !scanner.hosts.isEmpty {
                resultsSection
            }
            importedSection
        }
        .navigationTitle("Local network")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $trustReport) { report in
            TrustReportSheet(report: report).environment(\.zenPalette, palette)
        }
        .onDisappear { scanner.cancel() }
    }

    // MARK: Scanning

    private var subnet: IPv4Subnet? { scanner.subnet ?? LANScanController.currentSubnet() }

    private var scanSection: some View {
        Section {
            if let subnet {
                LabeledContent("Network", value: subnet.displayCIDR)
                LabeledContent("Addresses", value: "\(subnet.hostCount)")
            } else {
                Text("No Wi-Fi network found.")
                    .foregroundStyle(.secondary)
            }

            TextField("Extra ports, e.g. 7860, 11434", text: $customPortText)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .accessibilityIdentifier("customPortsField")

            Toggle("Also sweep 1–1024", isOn: $includePrivileged)
                .accessibilityIdentifier("privilegedPortsToggle")
            if includePrivileged {
                Label(
                    "A full low-port sweep looks exactly like a port scan to anything "
                        + "watching, and takes minutes. Fine on your own network; think "
                        + "twice on anyone else's.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 12))
                .foregroundStyle(ZenTokens.warningColor.color)
            }
            if let subnet, subnet.isWiderThanComfortable {
                Label(
                    subnet.wasClamped
                        ? "That network is wider than a /22; the scan is capped at "
                            + "\(subnet.displayCIDR)."
                        : "\(subnet.hostCount) addresses is a long scan. Cancel is always "
                            + "there.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 12))
                .foregroundStyle(ZenTokens.warningColor.color)
            }

            if scanner.isScanning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: scanner.progress)
                    Text(scanner.phase.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    scanner.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .accessibilityIdentifier("stopScanButton")
            } else {
                Button {
                    startScan()
                } label: {
                    Label(
                        scanner.hosts.isEmpty ? "Scan" : "Scan again",
                        systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(subnet == nil)
                .accessibilityIdentifier("scanButton")
                if case .failed(let reason) = scanner.phase {
                    Text(reason).foregroundStyle(ZenTokens.warningColor.color)
                }
            }
        } header: {
            Text("Scan")
        } footer: {
            Text(
                "Two passes: every address is checked for signs of life first, then "
                    + "only the hosts that answered get the full port list — a refused "
                    + "connection proves a host is there, which is what makes this fast. "
                    + "A device that silently drops everything will not show up. "
                    + "Bonjour and reverse DNS run alongside and supply the names.")
        }
    }

    private func startScan() {
        guard let subnet else { return }
        selection = []
        importedCount = nil
        let configuration = LANScanConfiguration(
            subnet: subnet, customPorts: Self.parsePorts(customPortText),
            includePrivilegedRange: includePrivileged)
        Haptics.shared.fire(.urlCommit)
        scanner.start(configuration)
    }

    /// `8000, 9090 3000` — commas, spaces or both, because people type both.
    static func parsePorts(_ text: String) -> [Int] {
        text
            .split(whereSeparator: { ",; ".contains($0) || $0.isWhitespace })
            .compactMap { Int($0) }
            .filter { (1...65535).contains($0) }
    }

    // MARK: Results

    private var resultsSection: some View {
        Section {
            if scanner.hosts.isEmpty {
                Text(scanner.isScanning ? "Looking…" : "Nothing answered.")
                    .foregroundStyle(.secondary)
            }
            ForEach(scanner.hosts) { host in
                DisclosureGroup {
                    if host.ports.isEmpty {
                        Text("No open ports from the list.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(host.ports) { port in
                        findingRow(host: host, port: port)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.shortName)
                            .font(.system(size: 15, weight: .medium))
                        HStack(spacing: 6) {
                            Text(host.address)
                            if !host.ports.isEmpty {
                                Text("· \(host.ports.count) open")
                            }
                            if !host.bonjourServices.isEmpty {
                                Text("· Bonjour")
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if !selection.isEmpty {
                Button {
                    importSelected()
                } label: {
                    Label("Import \(selection.count) selected", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("importSelectedButton")
            }
            if let importedCount {
                Text("Imported \(importedCount). They are in Local now.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Found")
                Spacer()
                if !scanner.hosts.isEmpty {
                    Button(selection.isEmpty ? "Select all" : "Clear") {
                        selection = selection.isEmpty ? Set(allFindingKeys) : []
                    }
                    .font(.system(size: 12))
                    .textCase(nil)
                }
            }
        } footer: {
            Text(
                "Page titles and certificates come from a single request to `/` on "
                    + "each web port, made without trusting the certificate — the "
                    + "fingerprint is what you compare against the device itself.")
        }
    }

    private var allFindingKeys: [String] {
        scanner.hosts.flatMap { host in
            host.ports.compactMap { $0.url(host: host.address)?.absoluteString }
        }
    }

    private func findingRow(host: LANDiscoveredHost, port: LANDiscoveredPort) -> some View {
        let url = port.url(host: host.address)
        let key = url?.absoluteString ?? "\(host.address):\(port.port)"
        let selected = selection.contains(key)
        let alreadyKept = url.flatMap { store.service(for: $0) } != nil
        return Button {
            guard url != nil else { return }
            if selected { selection.remove(key) } else { selection.insert(key) }
            Haptics.shared.fire(.suggestionPick)
        } label: {
            HStack(spacing: 10) {
                Image(
                    systemName: url == nil
                        ? "minus.circle"
                        : (selected ? "checkmark.circle.fill" : "circle")
                )
                .foregroundStyle(selected ? palette.accent.color : .secondary)
                Image(systemName: port.kind.symbol)
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(port.pageTitle ?? port.kind.name)
                        .font(.system(size: 14))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("Port \(port.port)")
                        if port.certificate != nil { Text("· TLS") }
                        if alreadyKept { Text("· kept") }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .disabled(url == nil)
        .accessibilityIdentifier("finding-\(host.address)-\(port.port)")
    }

    private func importSelected() {
        var count = 0
        for host in scanner.hosts {
            for port in host.ports {
                guard let url = port.url(host: host.address),
                    selection.contains(url.absoluteString)
                else { continue }
                var service = LocalService(
                    alias: LocalService.suggestedAlias(host: host, port: port),
                    host: host.address, hostname: host.hostname, port: port.port, url: url,
                    certificate: port.certificate)
                // A name we already chose for this address wins over a page
                // title that changed since — renaming is a decision.
                if let existing = store.service(for: url) { service.alias = existing.alias }
                store.importService(service)
                count += 1
            }
        }
        Haptics.shared.fire(.tabRestore)
        importedCount = count
        selection = []
    }

    // MARK: What was kept

    private var importedSection: some View {
        Section {
            NavigationLink {
                LocalServicesList(state: state, store: store)
                    .environment(\.zenPalette, palette)
                    .navigationTitle("Local services")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                HStack {
                    Label("Local services", systemImage: "network")
                    Spacer()
                    Text("\(store.services.count)").foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("localServicesRow")

            Button {
                trustAllHTTPS()
            } label: {
                Label("Trust certificates", systemImage: "checkmark.shield")
            }
            .disabled(httpsServices.isEmpty)
            .accessibilityIdentifier("trustCertificatesButton")

            if !store.isEmpty {
                Button(role: .destructive) {
                    store.forgetAll()
                } label: {
                    Label("Forget all local services", systemImage: "trash")
                }
            }
        } header: {
            Text("Kept")
        } footer: {
            Text(
                "Trust certificates approves the certificate each imported HTTPS "
                    + "service is currently serving, so those sites open without a "
                    + "prompt. It shows you exactly what it approved, and a host that "
                    + "later serves a *different* certificate will ask again — that is "
                    + "the whole point of keying on the fingerprint.")
        }
    }

    private var httpsServices: [LocalService] {
        store.services.filter { $0.isHTTPS && $0.certificate != nil }
    }

    private func trustAllHTTPS() {
        var trusted: [TrustReport.Entry] = []
        for service in httpsServices {
            guard let certificate = service.certificate,
                let host = service.url.host
            else { continue }
            let verdict = state.trustedCertificates.verdict(
                host: host, fingerprint: certificate.fingerprint)
            state.trustedCertificates.trust(host: host, fingerprint: certificate.fingerprint)
            store.acknowledgeCertificate(service)
            trusted.append(
                TrustReport.Entry(
                    alias: service.alias, host: host,
                    fingerprint: certificate.displayFingerprint,
                    subject: certificate.subject,
                    wasAlreadyTrusted: verdict == .trusted))
        }
        Haptics.shared.fire(.tabRestore)
        trustReport = TrustReport(entries: trusted)
    }
}

/// What "Trust certificates" actually did. A button that silently approves
/// things is not a button anybody should press.
struct TrustReport: Identifiable {
    struct Entry: Identifiable {
        var id: String { "\(host)|\(fingerprint)" }
        let alias: String
        let host: String
        let fingerprint: String
        let subject: String
        let wasAlreadyTrusted: Bool
    }

    let id = UUID()
    let entries: [Entry]
}

struct TrustReportSheet: View {
    let report: TrustReport
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zenPalette) private var palette

    var body: some View {
        NavigationStack {
            List {
                if report.entries.isEmpty {
                    ContentUnavailableView(
                        "Nothing to trust", systemImage: "checkmark.shield",
                        description: Text(
                            "None of the imported services are HTTPS with a certificate "
                                + "captured during the scan."))
                }
                ForEach(report.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.alias).font(.system(size: 15, weight: .medium))
                            Spacer()
                            if entry.wasAlreadyTrusted {
                                Text("already trusted")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(entry.host)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(entry.subject)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(entry.fingerprint)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Trusted \(report.entries.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(palette.accent.color)
    }
}
