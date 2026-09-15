//  LocalServiceStore.swift
//  The services you kept from a LAN scan.
//
//  Small enough to be one JSON document, like history and bookmarks. Identity
//  is the *URL*, not the alias: renaming `10.0.0.80:8006` from "pve" to
//  "proxmox" must not create a second entry, and importing the same host twice
//  must update the one that is there rather than stacking duplicates.

import Foundation

@MainActor
final class LocalServiceStore: ObservableObject {
    @Published private(set) var services: [LocalService] = []

    private let file: JSONFileStore<[LocalService]>

    init(file: JSONFileStore<[LocalService]>? = nil) {
        self.file = file ?? JSONFileStore<[LocalService]>(name: "local-services.json")
        services = (self.file.load() ?? []).sorted { $0.alias < $1.alias }
    }

    var isEmpty: Bool { services.isEmpty }

    /// Grouped for display: one section per host, addresses ordered by port.
    var byHost: [(host: String, services: [LocalService])] {
        let groups = Dictionary(grouping: services) { $0.hostname ?? $0.host }
        return groups
            .map { (host: $0.key, services: $0.value.sorted { $0.port < $1.port }) }
            .sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
    }

    func service(for url: URL) -> LocalService? {
        services.first { $0.url == url }
    }

    /// Import a finding. An address already on the list has its last-seen date
    /// refreshed and — if the certificate moved — gets flagged rather than
    /// silently updated: a changed certificate on a known host is the one
    /// thing worth interrupting someone for (#00889 draws the same line).
    @discardableResult
    func importService(_ incoming: LocalService) -> LocalService {
        guard let index = services.firstIndex(where: { $0.url == incoming.url }) else {
            var added = incoming
            added.lastSeen = Date()
            added.addedAt = Date()
            services.append(added)
            sortAndPersist()
            return added
        }
        var existing = services[index]
        existing.lastSeen = Date()
        existing.hostname = incoming.hostname ?? existing.hostname
        if let new = incoming.certificate {
            if let old = existing.certificate, old.fingerprint != new.fingerprint {
                existing.certificateChangedAt = Date()
            }
            existing.certificate = new
        }
        services[index] = existing
        sortAndPersist()
        return existing
    }

    /// Fold a whole scan in: refresh what we already keep, add nothing new.
    /// Called after a re-scan so "last seen" means something.
    func refresh(from hosts: [LANDiscoveredHost]) {
        var found: [URL: LANDiscoveredPort] = [:]
        for host in hosts {
            for port in host.ports {
                if let url = port.url(host: host.address) { found[url] = port }
            }
        }
        var changed = false
        for (index, service) in services.enumerated() {
            guard let port = found[service.url] else { continue }
            var updated = service
            updated.lastSeen = Date()
            if let new = port.certificate {
                if let old = service.certificate, old.fingerprint != new.fingerprint {
                    updated.certificateChangedAt = Date()
                }
                updated.certificate = new
            }
            guard updated != service else { continue }
            services[index] = updated
            changed = true
        }
        if changed { sortAndPersist() }
    }

    func rename(_ service: LocalService, to alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = services.firstIndex(where: { $0.id == service.id })
        else { return }
        services[index].alias = trimmed
        sortAndPersist()
    }

    func setNotes(_ notes: String, for service: LocalService) {
        guard let index = services.firstIndex(where: { $0.id == service.id }) else { return }
        services[index].notes = notes
        sortAndPersist()
    }

    /// Clear the "this certificate changed" flag — an acknowledgement, which is
    /// why nothing clears it on a timer.
    func acknowledgeCertificate(_ service: LocalService) {
        guard let index = services.firstIndex(where: { $0.id == service.id }) else { return }
        services[index].certificateChangedAt = nil
        sortAndPersist()
    }

    func forget(_ service: LocalService) {
        services.removeAll { $0.id == service.id }
        sortAndPersist()
    }

    func forgetAll() {
        services = []
        sortAndPersist()
    }

    // MARK: Omnibox

    /// Aliases and hostnames matching what is being typed, best first.
    ///
    /// Exact alias beats prefix beats substring, and the host is searched too,
    /// so `8006` finds the Proxmox box even if you called it something else.
    func suggestions(for rawQuery: String, limit: Int = 3) -> [LocalService] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        func rank(_ service: LocalService) -> Int? {
            let alias = service.alias.lowercased()
            let host = (service.hostname ?? service.host).lowercased()
            if alias == query || host == query { return 0 }
            if alias.hasPrefix(query) { return 1 }
            if host.hasPrefix(query) { return 2 }
            if alias.contains(query) { return 3 }
            if host.contains(query) || service.url.absoluteString.lowercased().contains(query) {
                return 4
            }
            return nil
        }
        var ranked: [(service: LocalService, score: Int)] = []
        for service in services {
            guard let score = rank(service) else { continue }
            ranked.append((service, score))
        }
        ranked.sort { left, right in
            left.score == right.score
                ? left.service.alias < right.service.alias : left.score < right.score
        }
        return ranked.prefix(limit).map(\.service)
    }

    /// A bare word that *is* an alias navigates rather than searching. Exact,
    /// case-insensitive, whole-string only — anything looser and typing
    /// `mail` would stop searching for mail.
    func exactMatch(_ rawQuery: String) -> LocalService? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }
        return services.first { service in
            if service.alias.lowercased() == query { return true }
            guard var name = service.hostname?.lowercased() else { return false }
            while name.hasSuffix(".") { name.removeLast() }
            return name == query
        }
    }

    private func sortAndPersist() {
        services.sort { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
        file.save(services)
    }
}
