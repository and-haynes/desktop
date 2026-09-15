//  ExtensionFixtures.swift
//  Reaching the extension fixtures from inside the test bundle.
//
//  `Tests/Fixtures` is a folder reference, so the directory structure survives
//  into the bundle and `Fixtures/Extensions/zen-badge` is a real directory
//  there rather than seven files flattened onto the bundle root. That matters
//  here more than anywhere else: two extensions both have a `manifest.json`,
//  and a flattened copy would have silently kept one of them.

import Foundation
import XCTest

@testable import Zen

enum ExtensionFixtures {
    static var bundle: Bundle { Bundle(for: FixtureAnchor.self) }

    /// One of the unpacked extension directories.
    static func directory(_ name: String, file: StaticString = #filePath, line: UInt = #line)
        throws -> URL
    {
        guard
            let url = bundle.url(
                forResource: name, withExtension: nil, subdirectory: "Fixtures/Extensions")
        else {
            XCTFail("fixture extension \(name) is not in the test bundle", file: file, line: line)
            throw FixtureError.missing(name)
        }
        return url
    }

    /// One of the packed archives (`.xpi`, `.crx`, `.zip`).
    static func archive(_ name: String, file: StaticString = #filePath, line: UInt = #line)
        throws -> Data
    {
        let parts = name.split(separator: ".")
        guard parts.count == 2,
            let url = bundle.url(
                forResource: String(parts[0]), withExtension: String(parts[1]),
                subdirectory: "Fixtures/Extensions/packed")
        else {
            XCTFail("fixture archive \(name) is not in the test bundle", file: file, line: line)
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    static func manifest(_ name: String, file: StaticString = #filePath, line: UInt = #line)
        throws -> ExtensionManifest
    {
        let directory = try self.directory(name, file: file, line: line)
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try ExtensionManifest.parse(data)
    }

    /// A scratch directory that the caller does not have to remember to clean:
    /// everything under one per-run root, removed by `cleanUp`.
    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-extensions-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    enum FixtureError: Error { case missing(String) }

    /// `Bundle(for:)` needs a class that lives in the test bundle.
    private final class FixtureAnchor {}
}
