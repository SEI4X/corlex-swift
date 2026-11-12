import Foundation

/// Makes what the app passes fit the protocol (port of `sdk-core/src/properties.ts`): long
/// strings are cut, what cannot be represented is dropped. `depth` follows the Go validator:
/// `properties` itself is level 1, and an array counts as a level.
enum PropertySanitizer {
    static func sanitize(_ input: [String: Any]?) -> [String: JSONValue] {
        guard let input else { return [:] }
        return cleanDictionary(input, depth: 1)
    }

    private static func clean(_ value: Any, depth: Int) -> JSONValue? {
        if value is NSNull { return .null }
        if let number = value as? NSNumber { return cleanNumber(number) }
        if let text = value as? String { return .string(text.truncated(toUTF8Bytes: Limits.maxPropertyString)) }
        if let date = value as? Date { return .string(Timestamp.string(from: date)) }
        if let uuid = value as? UUID { return .string(uuid.uuidString.lowercased()) }
        if let items = value as? [Any] { return cleanArray(items, depth: depth) }
        if let object = value as? [String: Any] {
            return depth + 1 > Limits.maxDepth ? nil : .object(cleanDictionary(object, depth: depth + 1))
        }
        return nil
    }

    private static func cleanNumber(_ number: NSNumber) -> JSONValue {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        if CFNumberIsFloatType(number) {
            let double = number.doubleValue
            return double.isFinite ? .double(double) : .null
        }
        return .int(number.int64Value)
    }

    private static func cleanArray(_ items: [Any], depth: Int) -> JSONValue? {
        if depth + 1 > Limits.maxDepth { return nil }
        let cleaned = items.prefix(Limits.maxArray).map { clean($0, depth: depth + 1) ?? .null }
        return .array(Array(cleaned))
    }

    private static func cleanDictionary(_ object: [String: Any], depth: Int) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        // Sorted, so that the 100 kept keys do not depend on dictionary order.
        for rawKey in object.keys.sorted() {
            let key = rawKey.truncated(toUTF8Bytes: Limits.maxPropertyKey)
            if key.isEmpty || out.count >= Limits.maxProperties { continue }
            guard let raw = object[rawKey], let value = clean(raw, depth: depth) else { continue }
            out[key] = value
        }
        return out
    }
}

/// RFC 3339 times with milliseconds, as the protocol wants them.
enum Timestamp {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
}
