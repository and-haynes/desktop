//  ImportedPaletteStore.swift
//  Palettes the owner imports from a file, and the parser that reads them.
//
//  This is what stands in for Pantone (#0088F). Their values are licensed and
//  not ours to redistribute; a table of approximations under those names would
//  be a licence problem *and* a lie about colour accuracy. So the code lookup
//  searches a file you supply — from your brand deck, your design tool's
//  export, or your own notes — and the format is documented in the README so
//  it can be produced by hand in a minute.

import Foundation

struct ImportedPalette: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var entries: [Entry]
    var importedAt: Date = Date()

    struct Entry: Codable, Equatable, Sendable {
        /// The palette's own identifier — "PB-101", "Brand/Ink", "07".
        var code: String?
        var name: String
        /// Normalised to `#RRGGBB` at parse time.
        var hex: String
    }

    var namedColors: [NamedColor] {
        entries.map {
            NamedColor(
                name: $0.name, hex: $0.hex, collection: .imported, code: $0.code,
                paletteName: name)
        }
    }
}

enum PaletteImport {
    enum Failure: Error, Equatable {
        case notJSON
        case noColors
        /// Parsed, but every entry was unusable.
        case noUsableColors
    }

    /// Parse a palette file.
    ///
    /// Deliberately forgiving about *shape* and strict about *values*. Three
    /// layouts are accepted, because all three are what people's tools actually
    /// export, and rejecting two of them would send someone to a text editor
    /// for no reason:
    ///
    ///   { "name": "Brand", "colors": [ {"code": "PB-101", "name": "Ink",
    ///                                   "hex": "#0B3D5C"} ] }
    ///   [ {"name": "Ink", "hex": "#0B3D5C"} ]
    ///   { "Ink": "#0B3D5C", "Paper": "#F4ECD8" }
    ///
    /// An entry with an unreadable colour is dropped rather than failing the
    /// import — one bad row in a hundred should not cost you the other 99.
    static func parse(_ data: Data, fallbackName: String) throws -> ImportedPalette {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure.notJSON
        }

        var name = fallbackName
        var rawEntries: [[String: Any]] = []

        if let object = json as? [String: Any] {
            if let title = object["name"] as? String, !title.isEmpty { name = title }
            if let colors = object["colors"] as? [[String: Any]] {
                rawEntries = colors
            } else if let colors = object["swatches"] as? [[String: Any]] {
                rawEntries = colors
            } else {
                // The flat `{ "Ink": "#0B3D5C" }` shape.
                rawEntries = object.compactMap { key, value in
                    guard let hex = value as? String else { return nil }
                    return ["name": key, "hex": hex]
                }
            }
        } else if let array = json as? [[String: Any]] {
            rawEntries = array
        } else {
            throw Failure.noColors
        }

        guard !rawEntries.isEmpty else { throw Failure.noColors }

        let entries: [ImportedPalette.Entry] = rawEntries.compactMap { row in
            let rawHex =
                (row["hex"] as? String) ?? (row["value"] as? String) ?? (row["color"] as? String)
                ?? (row["colour"] as? String)
            guard let rawHex, let hex = NamedColorLibrary.normalisedHex(rawHex) else { return nil }
            let code = (row["code"] as? String) ?? (row["id"] as? String)
            let title = (row["name"] as? String) ?? (row["title"] as? String) ?? code ?? hex
            return ImportedPalette.Entry(code: code, name: title, hex: hex)
        }

        guard !entries.isEmpty else { throw Failure.noUsableColors }
        return ImportedPalette(name: name, entries: entries)
    }
}

@MainActor
final class ImportedPaletteStore: ObservableObject {
    @Published private(set) var palettes: [ImportedPalette] = []

    private let file: JSONFileStore<[ImportedPalette]>

    init(file: JSONFileStore<[ImportedPalette]>? = nil) {
        self.file = file ?? JSONFileStore<[ImportedPalette]>(name: "palettes.json")
        palettes = self.file.load() ?? []
    }

    /// Every imported colour, flattened for the code search.
    var namedColors: [NamedColor] { palettes.flatMap(\.namedColors) }

    /// Re-importing a palette of the same name replaces it, so fixing a typo
    /// and importing again does not leave two near-identical sets to search.
    func add(_ palette: ImportedPalette) {
        palettes.removeAll { $0.name.caseInsensitiveCompare(palette.name) == .orderedSame }
        palettes.insert(palette, at: 0)
        persist()
    }

    func remove(_ palette: ImportedPalette) {
        palettes.removeAll { $0.id == palette.id }
        persist()
    }

    private func persist() { file.save(palettes) }
}
