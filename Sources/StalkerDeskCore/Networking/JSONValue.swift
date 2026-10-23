//
//  JSONValue.swift
//  StalkerDeskCore
//
//  Stalker/Ministra is a legacy PHP API and returns JSON with a variety of
//  shapes: js may be an object, an array, a string, false, or missing. Rather
//  than fighting Codable with a dozen lossy wrappers, responses are decoded
//  once into JSONValue and mapped defensively into typed DTOs.
//

import Foundation

public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value.rounded() == value, abs(value) < Double(Int.max) {
                return String(Int(value))
            }
            return String(value)
        case .bool(let value): return value ? "1" : "0"
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value.trimmingCharacters(in: .whitespaces))
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public func first(_ keys: String...) -> JSONValue? {
        first(keys)
    }

    public func first(_ keys: [String]) -> JSONValue? {
        for key in keys {
            if let value = self[key], !value.isNull {
                return value
            }
        }
        return nil
    }

    public func firstString(_ keys: String...) -> String? {
        firstString(keys)
    }

    public func firstString(_ keys: [String]) -> String? {
        first(keys).flatMap { value in
            let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (string?.isEmpty == false) ? string : nil
        }
    }

    public func firstInt(_ keys: String...) -> Int? {
        first(keys)?.intValue
    }

    public func firstInt(_ keys: [String]) -> Int? {
        first(keys)?.intValue
    }

    public func firstBool(_ keys: String...) -> Bool? {
        first(keys)?.boolValue
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func first(_ keys: String...) -> JSONValue? {
        first(keys)
    }

    func first(_ keys: [String]) -> JSONValue? {
        for key in keys {
            if let value = self[key], !value.isNull {
                return value
            }
        }
        return nil
    }

    func firstString(_ keys: String...) -> String? {
        firstString(keys)
    }

    func firstString(_ keys: [String]) -> String? {
        first(keys).flatMap { value in
            let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (string?.isEmpty == false) ? string : nil
        }
    }

    func firstInt(_ keys: String...) -> Int? {
        first(keys)?.intValue
    }

    func firstInt(_ keys: [String]) -> Int? {
        first(keys)?.intValue
    }

    func firstBool(_ keys: String...) -> Bool? {
        first(keys)?.boolValue
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
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
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) <= Double(Int.max) {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Lenient parser

public enum StalkerJSONParser {
    /// Parses a Stalker response, tolerating UTF-8 BOMs, anti-XSSI prefixes,
    /// trailing commas, and raw control characters in strings. HTML responses
    /// (captive portals, expired API routes) produce a typed error.
    public static func parse(_ data: Data) throws -> JSONValue {
        guard !data.isEmpty else {
            throw StalkerError.invalidResponse("The portal returned an empty response.")
        }

        var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))

        guard !text.isEmpty else {
            throw StalkerError.invalidResponse("The portal returned an empty response.")
        }

        if text.hasPrefix("<") || text.lowercased().hasPrefix("<!doctype") {
            throw StalkerError.invalidResponse(
                "The portal returned an HTML page instead of JSON. Check the portal URL and endpoint."
            )
        }

        for prefix in [")]}'\n", ")]}'", "while(1);", "for(;;);"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        text = sanitizeTrailingCommas(text)
        text = escapeControlCharacters(in: text)

        guard let data = text.data(using: .utf8) else {
            throw StalkerError.invalidJSON("The response was not valid UTF-8.")
        }

        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            // Some old Ministra builds emit single-quoted keys or NaN. A
            // best-effort fallback via JSONSerialization occasionally rescues a
            // response with a top-level fragment.
            if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
               let value = JSONValue(any: object) {
                return value
            }
            throw StalkerError.invalidJSON("The portal returned malformed JSON.")
        }
    }

    private static func sanitizeTrailingCommas(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: ",\\s*([}\\]])") else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: "$1")
    }

    private static func escapeControlCharacters(in input: String) -> String {
        var output = String()
        output.reserveCapacity(input.utf8.count)
        var insideString = false
        var escaping = false

        for scalar in input.unicodeScalars {
            if escaping {
                output.unicodeScalars.append(scalar)
                escaping = false
                continue
            }
            if scalar == "\\" && insideString {
                output.unicodeScalars.append(scalar)
                escaping = true
                continue
            }
            if scalar == "\"" {
                insideString.toggle()
                output.unicodeScalars.append(scalar)
                continue
            }
            if insideString, scalar.value < 0x20 {
                switch scalar {
                case "\n": output.append("\\n")
                case "\r": output.append("\\r")
                case "\t": output.append("\\t")
                default:
                    output.append(" ")
                }
                continue
            }
            output.unicodeScalars.append(scalar)
        }
        return output
    }
}

private extension JSONValue {
    init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            var values: [JSONValue] = []
            values.reserveCapacity(value.count)
            for item in value {
                guard let converted = JSONValue(any: item) else { return nil }
                values.append(converted)
            }
            self = .array(values)
        case let value as [String: Any]:
            var object: [String: JSONValue] = [:]
            for (key, raw) in value {
                guard let converted = JSONValue(any: raw) else { return nil }
                object[key] = converted
            }
            self = .object(object)
        default:
            return nil
        }
    }
}
