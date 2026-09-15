//  BarPresetStore.swift
//  Bar layouts you saved yourself.
//
//  The four built-in presets are code (`BarPreset`), because they are part of
//  what the app *is*. These are the ones you made, which makes them data — and
//  the same `BarLayout` document either way, so a saved preset and an imported
//  JSON file are the same thing arriving by different doors.

import Foundation

struct SavedBarPreset: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var layout: BarLayout
    var savedAt: Date = Date()

    init(id: UUID = UUID(), name: String, layout: BarLayout) {
        self.id = id
        self.name = name
        self.layout = layout
    }

    private enum CodingKeys: String, CodingKey { case id, name, layout, savedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Name and layout are the record; without either there is nothing to
        // restore, so those two are the only required keys.
        name = try c.decode(String.self, forKey: .name)
        layout = try c.decode(BarLayout.self, forKey: .layout)
        id = c.lenient(.id, UUID())
        savedAt = c.lenient(.savedAt, Date())
    }
}

@MainActor
final class BarPresetStore: ObservableObject {
    @Published private(set) var presets: [SavedBarPreset] = []

    private let file: JSONFileStore<[SavedBarPreset]>

    init(file: JSONFileStore<[SavedBarPreset]>? = nil) {
        self.file = file ?? JSONFileStore<[SavedBarPreset]>(name: "bar-presets.json")
        presets = self.file.load() ?? []
    }

    /// Saving under a name that is already taken replaces it. Two presets
    /// called "Mine" is not a thing anybody wants, and overwriting is what the
    /// second save meant.
    func save(_ layout: BarLayout, as rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var stripped = layout.normalised()
        // A saved preset is its own thing: it must not claim to be the built-in
        // it happened to start from, or "reset to preset" would go somewhere
        // else than the name on the chip.
        stripped.presetID = nil
        presets.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        presets.append(SavedBarPreset(name: name, layout: stripped))
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        file.save(presets)
    }

    func remove(_ preset: SavedBarPreset) {
        presets.removeAll { $0.id == preset.id }
        file.save(presets)
    }
}
