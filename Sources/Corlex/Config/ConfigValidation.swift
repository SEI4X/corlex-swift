import Foundation

/// The same bounded compiled document is required from the network and persisted cache.
enum ConfigValidation {
    static let maxBytes = 1024 * 1024
    static let maxCacheBytes = maxBytes + 1024
    private static let reserved: Set<String> = ["__proto__", "constructor", "prototype"]
    private static let platforms: Set<String> = ["ios", "android", "web", "flutter", "react-native"]

    static func decode(_ data: Data) -> ConfigDocument? {
        guard bounded(data), let doc = try? JSONDecoder().decode(ConfigDocument.self, from: data), valid(doc) else { return nil }
        return doc
    }

    /// Count container nesting and object keys before JSONDecoder allocates a tree.
    static func bounded(_ data: Data, cache: Bool = false) -> Bool {
        guard data.count <= (cache ? maxCacheBytes : maxBytes) else { return false }
        var quoted = false, escaped = false, depth = 0, keys = 0
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                if depth > (cache ? 17 : 16) { return false }
            } else if byte == 125 || byte == 93 {
                depth -= 1
                if depth < 0 { return false }
            } else if byte == 58 {
                keys += 1
                if keys > 65536 { return false }
            }
        }
        return !quoted && depth == 0
    }

    static func valid(_ doc: ConfigDocument) -> Bool {
        guard doc.version >= 0, doc.version <= 9_007_199_254_740_991,
              text(doc.etag, 256), !doc.etag.isEmpty, doc.etag.utf8.allSatisfy({ (32...126).contains($0) }),
              doc.params.count <= 1000, Set(doc.params.map(\.k)).count == doc.params.count,
              doc.params.allSatisfy(validParam) else { return false }
        let experiments = doc.experiments ?? []
        let linked = experiments.compactMap(\.p)
        return experiments.count <= 1000 && Set(experiments.map(\.k)).count == experiments.count &&
            Set(linked).count == linked.count && experiments.allSatisfy(validExperiment)
    }

    private static func validParam(_ param: CompiledParam) -> Bool {
        guard key(param.k), (0...10000).contains(param.r), matches(param.t, param.v) else { return false }
        return param.o?.allSatisfy { platforms.contains($0.key) && matches(param.t, $0.value) } ?? true
    }

    private static func validExperiment(_ experiment: CompiledExperiment) -> Bool {
        guard key(experiment.k), text(experiment.s, 128), experiment.p.map(key) ?? true,
              (2...10).contains(experiment.v.count) else { return false }
        var previous = 0
        var names = Set<String>()
        for variant in experiment.v {
            guard text(variant.n, 128), names.insert(variant.n).inserted,
                  variant.b > previous, variant.b <= 10000, finite(variant.v) else { return false }
            previous = variant.b
        }
        return previous == 10000
    }

    private static func text(_ value: String, _ max: Int) -> Bool { !value.isEmpty && value.utf16.count <= max }
    private static func key(_ value: String) -> Bool { text(value, 128) && !reserved.contains(value) }
    private static func matches(_ type: String?, _ value: JSONValue) -> Bool {
        switch (type, value) {
        case ("bool", .bool), ("number", .int), ("string", .string): return true
        case ("number", .double(let number)): return number.isFinite
        case ("json", _): return finite(value)
        default: return false
        }
    }
    private static func finite(_ value: JSONValue) -> Bool {
        switch value {
        case .double(let number): return number.isFinite
        case .array(let values): return values.allSatisfy(finite)
        case .object(let values): return values.values.allSatisfy(finite)
        default: return true
        }
    }
}
