//  JSONFileStore.swift
//  Atomic read/write of a Codable value to Application Support.
//
//  Every persisted store in the app goes through here so that a crash or a jetsam
//  kill mid-write can never leave a truncated file — we write a sibling temp file
//  and `replaceItemAt` it into place, which is atomic on APFS.

import Foundation

struct JSONFileStore<Value: Codable> {
    let url: URL

    /// `directory` is created on demand; `name` includes the extension.
    init(name: String, directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory
        url = base.appendingPathComponent(name)
    }

    init(url: URL) {
        self.url = url
    }

    static var defaultDirectory: URL {
        let fm = FileManager.default
        let support =
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return support.appendingPathComponent("Zen", isDirectory: true)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.makeDecoder().decode(Value.self, from: data)
    }

    /// Throwing variant, so tests can tell "no file" apart from "corrupt file".
    func loadOrThrow() throws -> Value {
        let data = try Data(contentsOf: url)
        return try Self.makeDecoder().decode(Value.self, from: data)
    }

    @discardableResult
    func save(_ value: Value) -> Bool {
        do {
            try saveOrThrow(value)
            return true
        } catch {
            assertionFailure("Zen: failed to persist \(url.lastPathComponent): \(error)")
            return false
        }
    }

    func saveOrThrow(_ value: Value) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try Self.makeEncoder().encode(value)
        let temp = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)

        if fm.fileExists(atPath: url.path) {
            // replaceItemAt is the atomic swap; it also cleans up the temp file.
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
