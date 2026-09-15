//  ColorParsingTests.swift
//  Typed colours (#0088F) and appearance modes (#00890).
//
//  The parsing tests lean on round-trips: whatever a person types, the field
//  must show back the same colour, and whatever the picker produces must be
//  re-typeable. The error cases matter as much — refusing input without saying
//  why is how a colour field becomes unusable.

import XCTest
import SwiftUI

@testable import Zen

final class ColorParsingTests: XCTestCase {

    private func assertClose(
        _ a: ZenColor, _ b: ZenColor, accuracy: Double = 0.004,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.r, b.r, accuracy: accuracy, "red", file: file, line: line)
        XCTAssertEqual(a.g, b.g, accuracy: accuracy, "green", file: file, line: line)
        XCTAssertEqual(a.b, b.b, accuracy: accuracy, "blue", file: file, line: line)
    }

    private func parsed(_ input: String) -> ZenColor? {
        if case .success(let color) = ColorParsing.parse(input) { return color }
        return nil
    }

    // MARK: Hex

    func testHexAcceptsEveryAcceptedShape() {
        for input in ["#5B6EE1", "5B6EE1", "#5b6ee1", "5b6ee1", "  #5B6EE1  "] {
            guard case .success(let color) = ColorParsing.parseHex(input) else {
                return XCTFail("rejected \(input)")
            }
            XCTAssertEqual(ColorParsing.formatHex(color), "#5B6EE1", input)
        }
    }

    func testShorthandHexExpandsEachDigit() {
        guard case .success(let color) = ColorParsing.parseHex("#f0a") else {
            return XCTFail("rejected shorthand")
        }
        XCTAssertEqual(ColorParsing.formatHex(color), "#FF00AA")
    }

    func testHexRoundTrips() {
        for hex in ["#000000", "#FFFFFF", "#5B6EE1", "#101010", "#E2E2E2", "#7F3D9B"] {
            guard case .success(let color) = ColorParsing.parseHex(hex) else {
                return XCTFail("rejected \(hex)")
            }
            XCTAssertEqual(ColorParsing.formatHex(color), hex)
        }
    }

    /// Errors have to name the actual problem, not just fail.
    func testHexErrorsAreSpecific() {
        XCTAssertEqual(ColorParsing.parseHex(""), .failure(.empty))
        XCTAssertEqual(ColorParsing.parseHex("#"), .failure(.empty))
        XCTAssertEqual(ColorParsing.parseHex("#GGGGGG"), .failure(.badHexDigits))
        XCTAssertEqual(ColorParsing.parseHex("#12345"), .failure(.badHexLength(5)))
        XCTAssertEqual(ColorParsing.parseHex("#1234567"), .failure(.badHexLength(7)))
    }

    /// Eight-digit hex carries alpha, which a space accent cannot express —
    /// refusing is better than silently dropping the channel.
    func testHexWithAlphaIsRefusedRatherThanTruncated() {
        XCTAssertEqual(ColorParsing.parseHex("#5B6EE180"), .failure(.badHexLength(8)))
    }

    func testEveryHexErrorHasAMessage() {
        let errors: [ColorParseError] = [
            .empty, .badHexLength(5), .badHexDigits, .badComponentCount(2),
            .componentOutOfRange("300"), .notANumber("abc"),
        ]
        for error in errors {
            XCTAssertFalse(
                error.errorDescription?.isEmpty ?? true, "\(error) has no message")
        }
    }

    // MARK: RGB

    func testRGBAcceptsEveryAcceptedShape() {
        for input in [
            "91, 110, 225", "91,110,225", "91 110 225", "rgb(91,110,225)",
            "rgb(91, 110, 225)", "RGB(91 110 225)", "  91 , 110 , 225 ",
        ] {
            guard case .success(let color) = ColorParsing.parseRGB(input) else {
                return XCTFail("rejected \(input)")
            }
            XCTAssertEqual(ColorParsing.formatHex(color), "#5B6EE1", input)
        }
    }

    func testRGBRoundTrips() {
        for triplet in ["0, 0, 0", "255, 255, 255", "91, 110, 225", "16, 16, 16"] {
            guard case .success(let color) = ColorParsing.parseRGB(triplet) else {
                return XCTFail("rejected \(triplet)")
            }
            XCTAssertEqual(ColorParsing.formatRGB(color), triplet)
        }
    }

    func testRGBErrorsAreSpecific() {
        XCTAssertEqual(ColorParsing.parseRGB(""), .failure(.empty))
        XCTAssertEqual(ColorParsing.parseRGB("1, 2"), .failure(.badComponentCount(2)))
        XCTAssertEqual(ColorParsing.parseRGB("1, 2, 3, 4"), .failure(.badComponentCount(4)))
        XCTAssertEqual(ColorParsing.parseRGB("1, 2, 300"), .failure(.componentOutOfRange("300")))
        XCTAssertEqual(ColorParsing.parseRGB("1, 2, -5"), .failure(.componentOutOfRange("-5")))
        XCTAssertEqual(ColorParsing.parseRGB("1, 2, red"), .failure(.notANumber("red")))
    }

    // MARK: The combined field

    func testCombinedParserPicksTheRightReading() {
        assertClose(parsed("#5B6EE1")!, ZenColor(91, 110, 225))
        assertClose(parsed("5B6EE1")!, ZenColor(91, 110, 225))
        assertClose(parsed("91, 110, 225")!, ZenColor(91, 110, 225))
        assertClose(parsed("rgb(91,110,225)")!, ZenColor(91, 110, 225))
        assertClose(parsed("91 110 225")!, ZenColor(91, 110, 225))
    }

    /// `#ggg` should complain about hex digits, not about needing three numbers.
    func testCombinedParserReportsTheLikelyFormatsError() {
        guard case .failure(let error) = ColorParsing.parse("#ggg") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error, .badHexDigits)
    }

    func testCombinedParserRejectsNonsense() {
        XCTAssertNil(parsed("chartreuse"))
        XCTAssertNil(parsed(""))
    }

    // MARK: 0–255 helpers

    func test255ComponentsRoundTrip() {
        let color = ZenColor(r255: 91, g255: 110, b255: 225)
        let components = color.rgb255
        XCTAssertEqual(components.r, 91)
        XCTAssertEqual(components.g, 110)
        XCTAssertEqual(components.b, 225)
    }

    func test255ComponentsAreClamped() {
        let color = ZenColor(r255: -10, g255: 300, b255: 128)
        XCTAssertEqual(color.rgb255.r, 0)
        XCTAssertEqual(color.rgb255.g, 255)
        XCTAssertEqual(color.rgb255.b, 128)
    }

    /// The wheel works in HSB, the fields in hex — a value must survive the
    /// trip through both without drifting.
    func testHSBToHexToHSBIsStable() {
        for hue in stride(from: 0.0, to: 1.0, by: 0.13) {
            let original = ZenColor(hue: hue, saturation: 0.8, brightness: 0.7)
            let viaHex = parsed(ColorParsing.formatHex(original))!
            assertClose(viaHex, original, accuracy: 0.01)
        }
    }

    func testPickedColoursAreAlwaysOpaque() {
        let color = ZenColor(r: 0.2, g: 0.4, b: 0.6, a: 0.3)
        XCTAssertEqual(color.withAlpha(1).a, 1)
        // And a parsed colour never carries alpha in the first place.
        XCTAssertEqual(parsed("#5B6EE1")!.a, 1)
    }
}

@MainActor
final class RecentColorsTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenRecent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> RecentColorsStore {
        RecentColorsStore(
            file: JSONFileStore<[ZenColor]>(name: "recent-colors.json", directory: directory))
    }

    func testMostRecentComesFirst() {
        let store = makeStore()
        store.record(ZenColor(hex: "#111111")!)
        store.record(ZenColor(hex: "#222222")!)
        XCTAssertEqual(store.colors.first?.hexString, "#222222")
    }

    func testRepickingMovesToFrontWithoutDuplicating() {
        let store = makeStore()
        store.record(ZenColor(hex: "#111111")!)
        store.record(ZenColor(hex: "#222222")!)
        store.record(ZenColor(hex: "#111111")!)
        XCTAssertEqual(store.colors.map(\.hexString), ["#111111", "#222222"])
    }

    func testOldestFallsOffPastTheLimit() {
        let store = makeStore()
        for index in 0..<(RecentColorsStore.limit + 4) {
            store.record(ZenColor(r255: index * 7, g255: 0, b255: 0))
        }
        XCTAssertEqual(store.colors.count, RecentColorsStore.limit)
    }

    func testRoundTripsThroughDisk() {
        makeStore().record(ZenColor(hex: "#5B6EE1")!)
        XCTAssertEqual(makeStore().colors.first?.hexString, "#5B6EE1")
    }

    func testRecordedColoursAreOpaque() {
        let store = makeStore()
        store.record(ZenColor(r: 0.1, g: 0.2, b: 0.3, a: 0.5))
        XCTAssertEqual(store.colors.first?.a, 1)
    }
}
