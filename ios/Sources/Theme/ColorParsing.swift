//  ColorParsing.swift
//  Typing a colour in, and printing one back out.
//
//  Zen's gradient generator lets you name a colour exactly rather than only
//  poking at a wheel, so the text paths have to be as trustworthy as the
//  graphical one: a value that round-trips, and an error that says what is
//  wrong rather than just refusing.

import Foundation

/// What went wrong with a typed colour, in words a person can act on.
enum ColorParseError: Equatable, LocalizedError {
    case empty
    case badHexLength(Int)
    case badHexDigits
    case badComponentCount(Int)
    case componentOutOfRange(String)
    case notANumber(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a colour."
        case .badHexLength(let count):
            return "Hex colours are 3 or 6 digits — this has \(count)."
        case .badHexDigits:
            return "Hex colours use 0–9 and A–F only."
        case .badComponentCount(let count):
            return "Enter three numbers for red, green and blue — this has \(count)."
        case .componentOutOfRange(let value):
            return "\(value) is outside 0–255."
        case .notANumber(let token):
            return "\"\(token)\" is not a number."
        }
    }
}

enum ColorParsing {

    // MARK: Hex

    /// Accepts `#RRGGBB`, `RRGGBB`, `#RGB`, `RGB`, in any case and with
    /// surrounding whitespace. Alpha is deliberately not accepted here: a space
    /// accent is opaque, and silently dropping an alpha channel would be worse
    /// than refusing it.
    static func parseHex(_ input: String) -> Result<ZenColor, ColorParseError> {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if text.hasPrefix("#") { text.removeFirst() }
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.allSatisfy({ $0.isHexDigit }) else { return .failure(.badHexDigits) }
        guard text.count == 3 || text.count == 6 else {
            return .failure(.badHexLength(text.count))
        }
        guard let color = ZenColor(hex: text) else { return .failure(.badHexDigits) }
        return .success(color)
    }

    /// `#RRGGBB`, uppercase — the form the fields display and the clipboard gets.
    static func formatHex(_ color: ZenColor) -> String {
        color.hexString
    }

    // MARK: RGB triplets

    /// Accepts `12, 34, 56`, `12 34 56`, `rgb(12,34,56)` and `rgb(12 34 56)`.
    /// Components are 0–255 integers.
    static func parseRGB(_ input: String) -> Result<ZenColor, ColorParseError> {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return .failure(.empty) }
        if text.hasPrefix("rgb") {
            text.removeFirst(3)
            text = text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("(") { text.removeFirst() }
            if text.hasSuffix(")") { text.removeLast() }
        }
        let tokens =
            text
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard tokens.count == 3 else { return .failure(.badComponentCount(tokens.count)) }

        var components: [Double] = []
        for token in tokens {
            guard let value = Double(token) else { return .failure(.notANumber(token)) }
            guard value >= 0, value <= 255 else {
                return .failure(.componentOutOfRange(token))
            }
            components.append(value / 255)
        }
        return .success(
            ZenColor(r: components[0], g: components[1], b: components[2]))
    }

    static func formatRGB(_ color: ZenColor) -> String {
        let scale = { (v: Double) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return "\(scale(color.r)), \(scale(color.g)), \(scale(color.b))"
    }

    // MARK: Either

    /// Try hex first, then an RGB triplet — what the single "paste a colour"
    /// field needs. The returned error is whichever form the input most looks
    /// like, so pasting `#ggg` complains about hex digits rather than about
    /// needing three numbers.
    static func parse(_ input: String) -> Result<ZenColor, ColorParseError> {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        let looksLikeRGB =
            text.lowercased().hasPrefix("rgb") || text.contains(",")
            || text.split(whereSeparator: { $0 == " " }).count == 3
        if looksLikeRGB { return parseRGB(text) }
        let hex = parseHex(text)
        if case .success = hex { return hex }
        // A bare "255 0 0" with odd spacing still deserves the RGB reading.
        if case .success(let color) = parseRGB(text) { return .success(color) }
        return hex
    }
}

extension ZenColor {
    /// 0–255 integer components, for the numeric fields.
    var rgb255: (r: Int, g: Int, b: Int) {
        let scale = { (v: Double) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return (scale(r), scale(g), scale(b))
    }

    init(r255: Int, g255: Int, b255: Int) {
        self.init(
            r: Double(min(max(r255, 0), 255)) / 255,
            g: Double(min(max(g255, 0), 255)) / 255,
            b: Double(min(max(b255, 0), 255)) / 255)
    }
}
