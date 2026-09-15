//  NamedColorLibraryTests.swift
//  Search ranking and palette parsing (#0088F).
//
//  Both are the sort of thing that "works" on the three examples you tried and
//  quietly fails on the fourth, which is exactly why they are pinned here.

import XCTest

@testable import Zen

final class NamedColorLibraryTests: XCTestCase {

    // MARK: The bundled library

    func testTheLibraryIsInTheBundle() {
        XCTAssertGreaterThan(
            NamedColorLibrary.bundled.count, 140,
            "the CSS/X11 set alone is ~148 entries — the JSON is not being found")
    }

    func testItCarriesBothCollections() {
        let collections = Set(NamedColorLibrary.bundled.map(\.collection))
        XCTAssertTrue(collections.contains(.css))
        XCTAssertTrue(collections.contains(.designer))
    }

    func testEveryBundledColourParses() {
        for entry in NamedColorLibrary.bundled {
            XCTAssertNotNil(entry.color, "\(entry.name) has an unreadable hex: \(entry.hex)")
        }
    }

    /// Nothing licensed is bundled, and that is a promise the tests keep.
    func testNoLicensedColourSystemIsBundled() {
        // Whole words, not substrings: "coral" contains "ral" and "floralwhite"
        // contains it twice, and neither is Pantone's problem.
        let forbidden: Set<String> = ["pantone", "pms", "ral", "ncs"]
        for entry in NamedColorLibrary.bundled {
            let words = Set(
                entry.name.lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map(String.init))
            XCTAssertTrue(
                words.isDisjoint(with: forbidden),
                "\(entry.name) looks like a licensed colour system")
        }
    }

    // MARK: Search ranking

    func testAnExactNameComesFirst() {
        XCTAssertEqual(NamedColorLibrary.search("teal").first?.name, "teal")
        XCTAssertEqual(NamedColorLibrary.search("Teal").first?.name, "teal")
    }

    func testAPrefixBeatsASubstring() {
        let results = NamedColorLibrary.search("sea")
        guard let first = results.first else { return XCTFail("no results for 'sea'") }
        XCTAssertTrue(
            first.name.lowercased().hasPrefix("sea"),
            "'sea' should rank seagreen/seashell above lightseagreen, got \(first.name)")
    }

    func testASubstringStillMatches() {
        let names = NamedColorLibrary.search("violet").map(\.name)
        XCTAssertTrue(names.contains("blueviolet"))
        XCTAssertTrue(names.contains("darkviolet"))
    }

    func testAMultiWordQueryMatchesInAnyOrder() {
        let names = NamedColorLibrary.search("sea deep").map(\.name)
        XCTAssertTrue(names.contains("Deep Sea"), "expected the designer swatch, got \(names)")
    }

    func testAnEmptyQueryReturnsTheLibrary() {
        XCTAssertFalse(NamedColorLibrary.search("").isEmpty)
    }

    func testNonsenseReturnsNothing() {
        XCTAssertTrue(NamedColorLibrary.search("qqzzxx").isEmpty)
    }

    // MARK: Hex queries

    func testAPastedHexFindsTheNameForIt() {
        XCTAssertEqual(NamedColorLibrary.search("#4169E1").first?.name, "royalblue")
        XCTAssertEqual(NamedColorLibrary.search("4169e1").first?.name, "royalblue")
    }

    func testShorthandHexExpands() {
        XCTAssertEqual(NamedColorLibrary.normalisedHex("#f00"), "#FF0000")
        XCTAssertEqual(NamedColorLibrary.normalisedHex("abc"), "#AABBCC")
    }

    func testThingsThatAreNotHexAreTreatedAsNames() {
        XCTAssertNil(NamedColorLibrary.normalisedHex("teal"))
        XCTAssertNil(NamedColorLibrary.normalisedHex("#12345"))
        XCTAssertNil(NamedColorLibrary.normalisedHex("#gggggg"))
        XCTAssertNil(NamedColorLibrary.normalisedHex(""))
    }

    // MARK: Palette import

    private func parse(_ json: String, name: String = "Test") throws -> ImportedPalette {
        try PaletteImport.parse(Data(json.utf8), fallbackName: name)
    }

    func testTheDocumentedShapeParses() throws {
        let palette = try parse(
            """
            {"name":"Brand","colors":[
              {"code":"PB-101","name":"Deep Sea","hex":"#0B3D5C"},
              {"code":"PB-102","name":"Paper","hex":"#F4ECD8"}]}
            """)
        XCTAssertEqual(palette.name, "Brand")
        XCTAssertEqual(palette.entries.count, 2)
        XCTAssertEqual(palette.entries.first?.code, "PB-101")
        XCTAssertEqual(palette.entries.first?.hex, "#0B3D5C")
    }

    func testABareArrayParses() throws {
        let palette = try parse(##"[{"name":"Ink","hex":"#101010"}]"##, name: "brand-deck")
        XCTAssertEqual(palette.name, "brand-deck", "the file name stands in for a missing title")
        XCTAssertEqual(palette.entries.first?.name, "Ink")
    }

    func testAFlatDictionaryParses() throws {
        let palette = try parse(##"{"Ink":"#101010","Paper":"#F4ECD8"}"##)
        XCTAssertEqual(palette.entries.count, 2)
        XCTAssertTrue(palette.entries.contains { $0.name == "Ink" && $0.hex == "#101010" })
    }

    func testAlternativeKeyNamesAreAccepted() throws {
        let palette = try parse(##"{"colors":[{"id":"07","title":"Rust","value":"#A8492A"}]}"##)
        XCTAssertEqual(palette.entries.first?.code, "07")
        XCTAssertEqual(palette.entries.first?.name, "Rust")
        XCTAssertEqual(palette.entries.first?.hex, "#A8492A")
    }

    func testShorthandAndBareHexAreNormalised() throws {
        let palette = try parse(##"{"colors":[{"name":"A","hex":"f00"},{"name":"B","hex":"#0a0"}]}"##)
        XCTAssertEqual(palette.entries.map(\.hex), ["#FF0000", "#00AA00"])
    }

    /// One bad row should not cost you the other ninety-nine.
    func testUnreadableRowsAreDroppedNotFatal() throws {
        let palette = try parse(
            ##"{"colors":[{"name":"Good","hex":"#112233"},{"name":"Bad","hex":"not a colour"}]}"##)
        XCTAssertEqual(palette.entries.count, 1)
        XCTAssertEqual(palette.entries.first?.name, "Good")
    }

    func testAnEntryWithNoNameFallsBackToItsCodeThenItsHex() throws {
        let palette = try parse(##"{"colors":[{"code":"X1","hex":"#112233"},{"hex":"#445566"}]}"##)
        XCTAssertEqual(palette.entries.first?.name, "X1")
        XCTAssertEqual(palette.entries.last?.name, "#445566")
    }

    func testNonJSONIsRejected() {
        XCTAssertThrowsError(try parse("not json at all")) { error in
            XCTAssertEqual(error as? PaletteImport.Failure, .notJSON)
        }
    }

    func testAnEmptyPaletteIsRejected() {
        XCTAssertThrowsError(try parse(##"{"name":"Empty","colors":[]}"##)) { error in
            XCTAssertEqual(error as? PaletteImport.Failure, .noColors)
        }
    }

    func testAPaletteWithNoReadableColoursIsRejected() {
        XCTAssertThrowsError(try parse(##"{"colors":[{"name":"A","hex":"zzz"}]}"##)) { error in
            XCTAssertEqual(error as? PaletteImport.Failure, .noUsableColors)
        }
    }

    // MARK: Searching imported palettes by code

    func testImportedColoursAreFoundByCode() throws {
        let palette = try parse(
            ##"{"name":"Brand","colors":[{"code":"PB-101","name":"Deep Sea","hex":"#0B3D5C"}]}"##)
        let results = NamedColorLibrary.search("pb-101", in: palette.namedColors)
        XCTAssertEqual(results.first?.name, "Deep Sea")
        XCTAssertEqual(results.first?.collection, .imported)
        XCTAssertEqual(results.first?.paletteName, "Brand")
    }

    func testAPartialCodeMatches() throws {
        let palette = try parse(
            """
            {"name":"Brand","colors":[
              {"code":"PB-101","name":"A","hex":"#010101"},
              {"code":"PB-102","name":"B","hex":"#020202"},
              {"code":"XX-900","name":"C","hex":"#030303"}]}
            """)
        let results = NamedColorLibrary.search("pb-", in: palette.namedColors)
        XCTAssertEqual(results.count, 2)
    }
}
