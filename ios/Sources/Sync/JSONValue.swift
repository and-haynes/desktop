//  JSONValue.swift
//  A concrete JSON tree, because Sync records are not ours to define.
//
//  Zen desktop projects its spaces records from live browser state; its
//  gradient dots carry fields (`algorithm`, `lightness`, `type`, `isCustom`)
//  that mean nothing on a phone but must survive a round trip, or every sync
//  would hand the desktop back a lossy copy of its own theme and it would
//  re-upload the original — forever. Decoding into `[String: Any]` would make
//  that untypeable and unhashable; this enum keeps unknown branches intact and
//  `Equatable`.
//
//  `canonicalJSON` mirrors the desktop's function of the same name: recursively
//  sorted keys, `undefined` → `null`, so two structurally equal payloads
//  stringify identically and can be compared by digest.

import CryptoKit
import Foundation

indirect enum JSONValue: Codable, Equatable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unrepresentable JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Accessors

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var intValue: Int? { doubleValue.map { Int($0) } }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        default: return nil
        }
    }

    var isNull: Bool { self == .null }

    subscript(key: String) -> JSONValue? {
        get { objectValue?[key] }
        set {
            var object = objectValue ?? [:]
            object[key] = newValue
            self = .object(object)
        }
    }

    // MARK: Construction

    static func string(orNull value: String?) -> JSONValue {
        value.map { .string($0) } ?? .null
    }

    static func object(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for (key, value) in pairs { out[key] = value }
        return .object(out)
    }

    init(jsonString: String) throws {
        try self.init(jsonData: Data(jsonString.utf8))
    }

    init(jsonData: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: jsonData)
    }

    // MARK: Serialisation

    func serializedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func serializedString() throws -> String {
        String(decoding: try serializedData(), as: UTF8.self)
    }

    /// Deterministic serialisation with recursively sorted keys — the
    /// `canonicalJSON` of `ZenSpacesSyncModel`, so our digests and the
    /// desktop's agree about what "unchanged" means.
    var canonicalJSON: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .string(let value): return Self.quote(value)
        case .array(let values):
            return "[" + values.map(\.canonicalJSON).joined(separator: ",") + "]"
        case .object(let object):
            let body = object.keys.sorted().map { key in
                Self.quote(key) + ":" + object[key]!.canonicalJSON
            }
            return "{" + body.joined(separator: ",") + "}"
        }
    }

    /// Base64 SHA-256 of the canonical form — the same digest the desktop
    /// stores in its uploaded-state snapshot.
    var digest: String {
        Data(SHA256.hash(data: Data(canonicalJSON.utf8))).base64EncodedString()
    }

    private static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
