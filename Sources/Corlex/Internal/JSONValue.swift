import Foundation

/// Any JSON value: what travels in event properties and what a Remote Config parameter holds.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// The kind as `get` compares it with the fallback: numbers are one kind, arrays and objects differ.
    var kind: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .int, .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// The plain Foundation value, for handing to the app.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return Int(value)
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.any)
        case .object(let value): return value.mapValues(\.any)
        }
    }

    /// The value from what the app passed in: `Bool`, numbers, `String`, arrays and dictionaries.
    /// Anything else gives `nil`. Not limited in size; see `PropertySanitizer` for events.
    init?(any value: Any) {
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }
        case let text as String: self = .string(text)
        case let items as [Any]:
            self = .array(items.map { JSONValue(any: $0) ?? .null })
        case let object as [String: Any]:
            self = .object(object.compactMapValues { JSONValue(any: $0) })
        default: return nil
        }
    }
}
