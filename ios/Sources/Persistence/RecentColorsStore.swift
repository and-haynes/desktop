//  RecentColorsStore.swift
//  The colours you reached for last.
//
//  Picking a space accent is rarely a one-shot decision — you try one, look at
//  it against a page, and come back. Without a recents row every return trip
//  means finding the same point on the wheel again.

import Foundation

@MainActor
final class RecentColorsStore: ObservableObject {
    /// Most recent first.
    @Published private(set) var colors: [ZenColor] = []

    /// One row's worth on a phone. Past this the oldest falls off.
    static let limit = 12

    private let file: JSONFileStore<[ZenColor]>

    init(file: JSONFileStore<[ZenColor]>? = nil) {
        self.file = file ?? JSONFileStore<[ZenColor]>(name: "recent-colors.json")
        colors = self.file.load() ?? []
    }

    /// Record a colour. Re-picking one already in the list moves it to the
    /// front rather than duplicating it — near-identical entries would make the
    /// row useless.
    func record(_ color: ZenColor) {
        let opaque = color.withAlpha(1)
        colors.removeAll { $0.hexString == opaque.hexString }
        colors.insert(opaque, at: 0)
        if colors.count > Self.limit { colors.removeLast(colors.count - Self.limit) }
        file.save(colors)
    }

    func clear() {
        colors = []
        file.save(colors)
    }
}
