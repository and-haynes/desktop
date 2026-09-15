//  NamedColorLibrary.swift
//  Colours you can ask for by name, and codes you can look up (#0088F).
//
//  The wheel is good for finding a colour and hopeless for finding *the*
//  colour: "the blue from the brand deck" is a name or a code, not a position
//  on a disc. So two lookups sit beside it — a bundled library of names, and a
//  code search over palettes you import yourself.
//
//  **Nothing licensed is bundled.** Pantone, RAL and NCS values are not free
//  to redistribute, and shipping a table of "close enough" numbers under those
//  names would be both a licence problem and a lie about colour accuracy. The
//  code field searches *your* palette file instead, which is yours to own.

import Foundation

struct NamedColor: Identifiable, Equatable, Sendable {
    enum Collection: String, Codable, Equatable, Sendable, CaseIterable {
        /// The CSS/X11 names, straight out of the CSS Color specification.
        case css
        /// A curated in-house set — the colours a person actually reaches for.
        case designer
        /// Loaded from a palette the user imported.
        case imported
    }

    var id: String { "\(collection.rawValue)-\(code ?? name)-\(hex)" }
    let name: String
    let hex: String
    let collection: Collection
    /// The palette's own code, for imported entries — "PB-101", "Brand/Ink".
    var code: String?
    /// Which imported palette it came from.
    var paletteName: String?

    var color: ZenColor? { ZenColor(hex: hex) }
}

/// The bundled library's on-disk shape.
struct NamedColorDocument: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let name: String
        let hex: String
        let collection: NamedColor.Collection
    }
    var version: Int
    var note: String?
    var colors: [Entry]
}

enum NamedColorLibrary {
    /// Parsed once. ~190 entries is nothing, but the search runs on every
    /// keystroke and re-decoding JSON each time would be silly.
    static let bundled: [NamedColor] = load()

    private static func load() -> [NamedColor] {
        let candidates: [Bundle] = [.main, Bundle(for: BundleToken.self)]
        for bundle in candidates {
            guard let url = bundle.url(forResource: "named-colors", withExtension: "json"),
                let data = try? Data(contentsOf: url),
                let document = try? JSONDecoder().decode(NamedColorDocument.self, from: data)
            else { continue }
            return document.colors.map {
                NamedColor(name: $0.name, hex: $0.hex.uppercased(), collection: $0.collection)
            }
        }
        assertionFailure("Zen: named-colors.json is not in the bundle")
        return []
    }

    private final class BundleToken {}

    /// Rank matches the way someone searching expects: the thing they typed
    /// exactly, then things starting with it, then things containing it. A hex
    /// query matches on the value instead, so pasting `#4169E1` finds
    /// "royalblue".
    static func search(_ rawQuery: String, in colors: [NamedColor] = bundled, limit: Int = 60)
        -> [NamedColor]
    {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return Array(colors.prefix(limit)) }

        // A hex query is a value lookup, not a name lookup.
        if let normalised = normalisedHex(query) {
            return colors.filter { $0.hex.uppercased() == normalised }
        }

        func score(_ entry: NamedColor) -> Int? {
            let name = entry.name.lowercased()
            let code = entry.code?.lowercased()
            if name == query || code == query { return 0 }
            if let code, code.hasPrefix(query) { return 1 }
            if name.hasPrefix(query) { return 2 }
            if let code, code.contains(query) { return 3 }
            if name.contains(query) { return 4 }
            // A multi-word query matches a name containing all its words, so
            // "deep blue" finds "deepskyblue" is *not* wanted — but "sea deep"
            // finding "Deep Sea" is.
            let words = query.split(separator: " ").map(String.init)
            if words.count > 1, words.allSatisfy({ name.contains($0) }) { return 5 }
            return nil
        }

        return
            colors
            .compactMap { entry -> (NamedColor, Int)? in
                score(entry).map { (entry, $0) }
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.name < rhs.0.name : lhs.1 < rhs.1
            }
            .prefix(limit)
            .map(\.0)
    }

    /// `4169e1`, `#4169E1` and `#41e` all mean the same colour.
    static func normalisedHex(_ query: String) -> String? {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 3 || text.count == 6,
            text.allSatisfy({ $0.isHexDigit })
        else { return nil }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        return "#" + text
    }
}
