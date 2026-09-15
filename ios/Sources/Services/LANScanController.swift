//  LANScanController.swift
//  Driving a scan: what to probe, how much is done, and how to stop.
//
//  The observable half of #0089C. `LANScanner.swift` holds the primitives — a
//  subnet, one TCP probe, one HTTP fingerprint — and this decides the order,
//  the concurrency and what the progress bar says.

import Foundation
import Network
import SwiftUI

struct LANScanConfiguration: Equatable, Sendable {
    var subnet: IPv4Subnet
    /// Extra ports beyond the catalogue, typed by hand.
    var customPorts: [Int] = []
    /// Sweep 1–1024 as well. Off by default and warned about: a full
    /// low-port sweep is indistinguishable from a port scan to anything
    /// watching, which on a network you do not own is not a neighbourly thing
    /// to do unannounced.
    var includePrivilegedRange = false
    var connectTimeout: TimeInterval = 1.0
    var httpTimeout: TimeInterval = 3.0
    /// How many TCP connects may be in flight. Beyond about this many the
    /// Network framework starts queuing anyway and the timeouts stop meaning
    /// what they say.
    var concurrency = 64

    /// The ports phase 2 probes, deduplicated and ordered.
    var ports: [Int] {
        var set = Set(LANPortCatalog.defaultPorts)
        set.formUnion(customPorts)
        if includePrivilegedRange { set.formUnion(LANPortCatalog.privilegedRange) }
        return set.filter { (1...65535).contains($0) }.sorted()
    }

    /// The ports phase 1 uses to decide a host exists at all. Three is enough:
    /// a live host *refuses* a closed port immediately, so what is being
    /// measured is reachability, not what it happens to run.
    static let livenessPorts = [80, 443, 22]
}

@MainActor
final class LANScanController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case permission
        case liveness
        case ports
        case fingerprinting
        case finished
        case cancelled
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .permission, .liveness, .ports, .fingerprinting: return true
            default: return false
            }
        }

        var message: String {
            switch self {
            case .idle: return "Ready"
            case .permission: return "Asking for local network access…"
            case .liveness: return "Looking for devices…"
            case .ports: return "Checking ports…"
            case .fingerprinting: return "Reading names and certificates…"
            case .finished: return "Done"
            case .cancelled: return "Stopped"
            case .failed(let reason): return reason
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    /// Hosts found so far, in address order. Published as the scan runs so the
    /// list fills in rather than appearing all at once at the end.
    @Published private(set) var hosts: [LANDiscoveredHost] = []
    @Published private(set) var subnet: IPv4Subnet?
    /// Bonjour names seen, keyed by address — folded into `hosts` as they
    /// arrive, and kept separately so a name can land after its host does.
    @Published private(set) var bonjourNames: [String: String] = [:]

    private var task: Task<Void, Never>?
    private var browsers: [NWBrowser] = []
    /// `type/name` pairs already resolved, so a browser update that repeats
    /// itself does not open the same connection again.
    private var resolvedServices: Set<String> = []

    var isScanning: Bool { phase.isRunning }

    /// The interface's own subnet, or nil where there is no Wi-Fi to speak of.
    static func currentSubnet() -> IPv4Subnet? {
        guard let interface = NetworkInterface.wifiIPv4() else { return nil }
        return IPv4Subnet(address: interface.address, netmask: interface.netmask)
    }

    func start(_ configuration: LANScanConfiguration) {
        cancel()
        hosts = []
        bonjourNames = [:]
        resolvedServices = []
        progress = 0
        subnet = configuration.subnet
        phase = .permission
        startBonjour()
        task = Task { await run(configuration) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        stopBonjour()
        if phase.isRunning { phase = .cancelled }
    }

    // MARK: The scan

    private func run(_ configuration: LANScanConfiguration) async {
        let addresses = configuration.subnet.hostAddresses
        guard !addresses.isEmpty else {
            phase = .failed("That subnet has no addresses to scan.")
            return
        }

        // 1. Liveness.
        phase = .liveness
        var live: [String] = []
        let livenessTotal = addresses.count
        var livenessDone = 0
        await withLimitedTaskGroup(limit: configuration.concurrency, over: addresses) {
            address in
            for port in LANScanConfiguration.livenessPorts {
                let result = await LANProbe.connect(
                    host: address, port: port, timeout: configuration.connectTimeout)
                if result != .silent { return (address, true) }
                if Task.isCancelled { return (address, false) }
            }
            return (address, false)
        } onResult: { [weak self] result in
            livenessDone += 1
            // Liveness is the long pass, so it owns most of the bar.
            self?.progress = 0.6 * Double(livenessDone) / Double(livenessTotal)
            if result.1 { live.append(result.0) }
        }
        guard !Task.isCancelled else {
            phase = .cancelled
            return
        }

        // Bonjour may have named a host that answered nothing at all.
        for address in bonjourNames.keys where !live.contains(address) {
            if configuration.subnet.hostAddresses.contains(address) { live.append(address) }
        }
        live.sort { (IPv4Subnet.parse($0) ?? 0) < (IPv4Subnet.parse($1) ?? 0) }

        guard !live.isEmpty else {
            progress = 1
            phase = .finished
            stopBonjour()
            return
        }

        // 2. Ports, on the live hosts only.
        phase = .ports
        let ports = configuration.ports
        var done = 0
        let total = live.count
        await withLimitedTaskGroup(limit: max(4, configuration.concurrency / 8), over: live) {
            address -> (String, [Int]) in
            var open: [Int] = []
            // Ports within one host run concurrently; the outer group is what
            // keeps the total number of sockets bounded.
            await withTaskGroup(of: (Int, LANProbeResult).self) { group in
                for port in ports {
                    group.addTask {
                        (
                            port,
                            await LANProbe.connect(
                                host: address, port: port,
                                timeout: configuration.connectTimeout)
                        )
                    }
                }
                for await (port, result) in group where result == .open {
                    open.append(port)
                }
            }
            return (address, open.sorted())
        } onResult: { [weak self] result in
            done += 1
            self?.progress = 0.6 + 0.25 * Double(done) / Double(total)
            guard let self else { return }
            var host = LANDiscoveredHost(address: result.0)
            host.hostname = self.bonjourNames[result.0]
            host.ports = result.1.map { LANDiscoveredPort(port: $0) }
            self.upsert(host)
        }
        guard !Task.isCancelled else {
            phase = .cancelled
            return
        }

        // 3. Names and page titles.
        phase = .fingerprinting
        await fingerprint(configuration)
        stopBonjour()
        progress = 1
        phase = Task.isCancelled ? .cancelled : .finished
    }

    /// Reverse DNS for every host, and `<title>` + certificate for every web
    /// port. Both are best effort: a scan that found the services is already
    /// useful, and nothing here is allowed to make it fail.
    private func fingerprint(_ configuration: LANScanConfiguration) async {
        let probe = LANHTTPProbe(timeout: configuration.httpTimeout)
        defer { probe.invalidate() }
        let snapshot = hosts
        var done = 0
        let total = max(1, snapshot.count)

        for host in snapshot {
            guard !Task.isCancelled else { return }
            var updated = host
            if updated.hostname == nil {
                let address = host.address
                if let bonjour = bonjourNames[address] {
                    updated.hostname = bonjour
                } else {
                    // `getnameinfo` blocks; off the main actor it goes.
                    updated.hostname = await Task.detached {
                        NetworkInterface.reverseDNS(of: address)
                    }.value
                }
            }
            await withTaskGroup(of: (Int, String?, LANCertificateInfo?).self) { group in
                for port in updated.ports where port.kind.isWeb {
                    guard let url = port.url(host: host.address) else { continue }
                    group.addTask {
                        let result = await probe.probe(url: url)
                        return (port.port, result.title, result.certificate)
                    }
                }
                for await (port, title, certificate) in group {
                    guard let index = updated.ports.firstIndex(where: { $0.port == port })
                    else { continue }
                    updated.ports[index].pageTitle = title
                    updated.ports[index].certificate = certificate
                }
            }
            upsert(updated)
            done += 1
            progress = 0.85 + 0.15 * Double(done) / Double(total)
        }
    }

    private func upsert(_ host: LANDiscoveredHost) {
        if let index = hosts.firstIndex(where: { $0.address == host.address }) {
            var merged = host
            // A name found by one pass must survive the next one overwriting
            // the record with a pass that did not look for names.
            merged.hostname = host.hostname ?? hosts[index].hostname
            merged.bonjourServices = hosts[index].bonjourServices.isEmpty
                ? host.bonjourServices : hosts[index].bonjourServices
            hosts[index] = merged
        } else {
            hosts.append(host)
            hosts.sort { (IPv4Subnet.parse($0.address) ?? 0) < (IPv4Subnet.parse($1.address) ?? 0) }
        }
    }

    // MARK: Bonjour

    /// Every service type the Info.plist declares. iOS only lets an app browse
    /// types it has listed in `NSBonjourServices`, so this list and that one
    /// have to stay in step.
    static let bonjourTypes = [
        "_http._tcp", "_https._tcp", "_ssh._tcp", "_sftp-ssh._tcp", "_smb._tcp",
        "_printer._tcp", "_ipp._tcp", "_airplay._tcp", "_homekit._tcp", "_hap._tcp",
        "_googlecast._tcp", "_workstation._tcp",
    ]

    private func startBonjour() {
        stopBonjour()
        for type in Self.bonjourTypes {
            let browser = NWBrowser(
                for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.absorb(results) }
            }
            browser.start(queue: .global(qos: .utility))
            browsers.append(browser)
        }
    }

    private func stopBonjour() {
        for browser in browsers { browser.cancel() }
        browsers = []
    }

    /// A Bonjour result is a *name*, not an address — `_http._tcp` tells you
    /// "Living Room Speaker" exists, not where. The address only appears once
    /// something connects, so each new service gets one throwaway connection
    /// whose `currentPath.remoteEndpoint` is the answer, then is cancelled.
    ///
    /// There are a handful of these on a home network, not hundreds, so a
    /// connection each is cheap — and it is the only way to line a Bonjour name
    /// up with the address the port scan found.
    private func absorb(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .service(let name, let type, _, _) = result.endpoint else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !resolvedServices.contains("\(type)/\(trimmed)") else {
                continue
            }
            resolvedServices.insert("\(type)/\(trimmed)")
            let endpoint = result.endpoint
            Task { [weak self] in
                guard let address = await Self.resolveAddress(of: endpoint) else { return }
                await MainActor.run {
                    self?.bonjourNames[address] = trimmed
                    self?.noteService(type, at: address)
                }
            }
        }
    }

    /// Resolve a Bonjour endpoint to an IPv4 address by connecting to it and
    /// reading the path back. Short deadline: a service that will not resolve
    /// must not hold anything up.
    private static func resolveAddress(of endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let box = ResolveBox()
            let finish: @Sendable (String?) -> Void = { address in
                box.complete(address) {
                    connection.cancel()
                    continuation.resume(returning: $0)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint
                    else {
                        finish(nil)
                        return
                    }
                    if case .ipv4(let v4) = host {
                        // `IPv4Address` prints with the interface zone attached
                        // ("10.0.0.42%en0"); the scan keys on the bare address.
                        finish("\(v4)".split(separator: "%").first.map(String.init))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { finish(nil) }
        }
    }

    private func noteService(_ type: String, at address: String) {
        guard let index = hosts.firstIndex(where: { $0.address == address }) else { return }
        if hosts[index].hostname == nil { hosts[index].hostname = bonjourNames[address] }
        guard !hosts[index].bonjourServices.contains(type) else { return }
        hosts[index].bonjourServices.append(type)
    }
}

/// Resumes a continuation exactly once, whichever of the state handler and the
/// deadline gets there first. Resuming twice is a crash, not a bug you find
/// later, so it is worth a type.
private final class ResolveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func complete(_ address: String?, _ body: (String?) -> Void) {
        lock.lock()
        let already = done
        done = true
        lock.unlock()
        guard !already else { return }
        body(address)
    }
}

// MARK: - Bounded concurrency

/// Run `work` over `items` with at most `limit` in flight, handing each result
/// back on the main actor as it lands.
///
/// `withTaskGroup` on its own would start every task at once — which for a /22
/// is four thousand sockets and an immediate `EMFILE`. Adding the next task
/// only as one finishes is the whole trick.
@MainActor
private func withLimitedTaskGroup<Item: Sendable, Result: Sendable>(
    limit: Int,
    over items: [Item],
    _ work: @escaping @Sendable (Item) async -> Result,
    onResult: @MainActor (Result) -> Void
) async {
    guard !items.isEmpty else { return }
    let limit = max(1, min(limit, items.count))
    var index = 0
    await withTaskGroup(of: Result.self) { group in
        while index < limit {
            let item = items[index]
            group.addTask { await work(item) }
            index += 1
        }
        while let result = await group.next() {
            onResult(result)
            guard !Task.isCancelled, index < items.count else { continue }
            let item = items[index]
            group.addTask { await work(item) }
            index += 1
        }
    }
}
