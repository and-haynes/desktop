//  HistoryStore.swift
//  A deliberately small JSON-backed history and bookmark store.
//
//  No SQLite: at the scale a phone browser actually accumulates (we cap at
//  5,000 entries) a linear scan over an in-memory array is faster than opening
//  a database, and it keeps the app dependency-free and the format inspectable.

import Foundation
import SwiftUI

struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var url: URL
    var title: String
    var lastVisited: Date
    var visitCount: Int = 1

    var displayTitle: String {
        title.isEmpty ? URLDetector.prettyHost(url) : title
    }
}

struct Bookmark: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var url: URL
    var title: String
    var createdAt: Date = Date()
    /// nil means "all spaces".
    var spaceID: UUID?
}

@MainActor
final class HistoryStore: ObservableObject {
    /// Newest first.
    @Published private(set) var entries: [HistoryEntry] = []

    /// Past this, the oldest entries are dropped on the next record.
    static let maxEntries = 5_000

    private let file: JSONFileStore<[HistoryEntry]>

    init(file: JSONFileStore<[HistoryEntry]>? = nil) {
        self.file = file ?? JSONFileStore<[HistoryEntry]>(name: "history.json")
        entries = self.file.load() ?? []
    }

    /// Record a visit. Revisiting a URL bumps it to the top and increments its
    /// count rather than adding a duplicate row.
    func record(url: URL, title: String) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        if let index = entries.firstIndex(where: { $0.url == url }) {
            var entry = entries.remove(at: index)
            entry.lastVisited = Date()
            entry.visitCount += 1
            if !title.isEmpty { entry.title = title }
            entries.insert(entry, at: 0)
        } else {
            entries.insert(
                HistoryEntry(url: url, title: title, lastVisited: Date()), at: 0)
        }
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        persist()
    }

    /// Hostnames with no dot in them: the machines on the local network, in
    /// practice. The omnibox uses these to decide that a bare `meitner` is a
    /// destination rather than a search — having been there once is the only
    /// evidence that separates the two.
    var singleLabelHosts: Set<String> {
        Set(
            entries.compactMap { entry in
                guard let host = entry.url.host?.lowercased(), !host.contains("."),
                    host != "localhost"
                else { return nil }
                return host
            })
    }

    /// Frecency-ish ranking for omnibox suggestions: prefix matches on the host
    /// beat substring matches, and more-visited beats less-visited.
    func suggestions(for query: String, limit: Int = 6) -> [HistoryEntry] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return Array(entries.prefix(limit)) }
        func score(_ e: HistoryEntry) -> Int? {
            let host = URLDetector.prettyHost(e.url).lowercased()
            let title = e.title.lowercased()
            let full = e.url.absoluteString.lowercased()
            var base: Int
            if host.hasPrefix(needle) {
                base = 1000
            } else if title.hasPrefix(needle) {
                base = 800
            } else if host.contains(needle) || full.contains(needle) {
                base = 400
            } else if title.contains(needle) {
                base = 200
            } else {
                return nil
            }
            return base + min(e.visitCount, 50)
        }
        return
            entries
            .compactMap { e -> (HistoryEntry, Int)? in score(e).map { (e, $0) } }
            .sorted { $0.1 == $1.1 ? $0.0.lastVisited > $1.0.lastVisited : $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clearAll() {
        entries = []
        persist()
    }

    private func persist() {
        file.save(entries)
    }
}

@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [Bookmark] = []

    private let file: JSONFileStore<[Bookmark]>

    init(file: JSONFileStore<[Bookmark]>? = nil) {
        self.file = file ?? JSONFileStore<[Bookmark]>(name: "bookmarks.json")
        bookmarks = self.file.load() ?? []
    }

    func isBookmarked(_ url: URL) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    /// Returns the new state, so the omnibox button can animate to it.
    @discardableResult
    func toggle(url: URL, title: String, spaceID: UUID?) -> Bool {
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: index)
            file.save(bookmarks)
            return false
        }
        bookmarks.insert(Bookmark(url: url, title: title, spaceID: spaceID), at: 0)
        file.save(bookmarks)
        return true
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        file.save(bookmarks)
    }
}
