//  FaviconService.swift
//  Fetches icons for tabs that have never been loaded.
//
//  Favicons are normally captured when a page finishes loading, but most tabs
//  in a restored session have never loaded in this process — so on a fresh
//  install the essentials grid is a row of monogram discs until you visit each
//  one. Browsers fetch icons for their pinned tabs up front; so do we.

import Foundation
import UIKit

enum FaviconService {
    /// Cap the launch burst. Essentials and pinned tabs are the ones whose
    /// icons are actually on screen, so they go first.
    private static let maxConcurrent = 4

    /// Fetch `/favicon.ico` for every tab missing an icon, icon-bearing tiers
    /// first. Failures are silent: a missing favicon is a cosmetic problem, not an
    /// error worth surfacing.
    @MainActor
    static func prefetchMissing(for state: BrowserState) async {
        let pending = state.tabs
            .filter { $0.faviconData == nil && !$0.isNewTabPage && $0.url.host != nil }
            .sorted { lhs, rhs in
                // essential < pinned < normal
                func rank(_ kind: TabKind) -> Int {
                    switch kind {
                    case .essential: return 0
                    case .pinned: return 1
                    case .normal: return 2
                    }
                }
                return rank(lhs.kind) < rank(rhs.kind)
            }
        guard !pending.isEmpty else { return }

        await withTaskGroup(of: (UUID, Data?).self) { group in
            var running = 0
            var iterator = pending.makeIterator()

            func addNext(_ group: inout TaskGroup<(UUID, Data?)>) -> Bool {
                guard let tab = iterator.next() else { return false }
                let id = tab.id
                let host = tab.url.host ?? ""
                let scheme = tab.url.scheme ?? "https"
                group.addTask {
                    (id, await fetch(scheme: scheme, host: host))
                }
                return true
            }

            while running < maxConcurrent, addNext(&group) { running += 1 }

            for await (id, data) in group {
                if let data { state.updateTab(id) { $0.faviconData = data } }
                _ = addNext(&group)
            }
        }
    }

    private static func fetch(scheme: String, host: String) async -> Data? {
        guard !host.isEmpty, let url = URL(string: "\(scheme)://\(host)/favicon.ico") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            data.count < 200_000,
            UIImage(data: data) != nil
        else { return nil }
        return data
    }
}
