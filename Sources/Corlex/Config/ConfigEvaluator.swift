import Foundation

/// Port of `packages/domain/src/flags/bucket.ts`, `remote-config/evaluate.ts` and
/// `remote-config/experiments.ts`. Pinned by the shared vectors in
/// `packages/domain/test-vectors/remote-config.json`: a person must land in the same bucket
/// here, on the server and in every other SDK.
enum Bucketing {
    /// Buckets per hundred percent: a rollout moves in steps of 0.01 %.
    static let buckets: UInt32 = 10_000

    /// FNV-1a over the UTF-8 bytes, then murmur3's finalizer so nearby inputs spread evenly.
    static func hash32(_ text: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        hash ^= hash >> 16
        hash = hash &* 0x85eb_ca6b
        hash ^= hash >> 13
        hash = hash &* 0xc2b2_ae35
        hash ^= hash >> 16
        return hash
    }

    /// The bucket (0 to 9999) of a person for a key; the NUL separator cannot occur in a key.
    static func bucket(key: String, userId: String) -> Int {
        Int(hash32("\(key)\u{0}\(userId)") % buckets)
    }
}

/// One parameter of the compiled document (`k`, `t`, `v`, `r`, `o`).
struct CompiledParam: Codable, Equatable {
    private enum CodingKeys: String, CodingKey { case k, t, v, r, o }
    var k: String
    var t: String?
    var v: JSONValue
    /// Rollout in buckets: percent times 100, 0 to 10 000.
    var r: Int
    var o: [String: JSONValue]?
}

struct CompiledVariant: Codable, Equatable {
    var n: String
    /// Exclusive upper bound of its bucket range.
    var b: Int
    var v: JSONValue
}

struct CompiledExperiment: Codable, Equatable {
    private enum CodingKeys: String, CodingKey { case k, s, p, v }
    var k: String
    var s: String
    var p: String?
    var v: [CompiledVariant]
}

/// The document edge-config serves (`GET /v1/config/document`).
struct ConfigDocument: Codable, Equatable {
    private enum CodingKeys: String, CodingKey { case version, etag, params, experiments }
    var version: Int
    var etag: String
    var params: [CompiledParam]
    var experiments: [CompiledExperiment]?
}

struct Assignment: Equatable {
    var variant: String
    var index: Int
    var value: JSONValue
}

enum ConfigEvaluator {
    /// What a person gets for a parameter, or nil when the rollout does not reach them: a
    /// platform override wins whatever the rollout says, then the stable bucket against `r`.
    static func resolve(_ param: CompiledParam, userId: String, platform: String?) -> JSONValue? {
        if let platform, let override = param.o?[platform] { return override }
        if param.r >= Int(Bucketing.buckets) || Bucketing.bucket(key: param.k, userId: userId) < param.r {
            return param.v
        }
        return nil
    }

    static func resolveAll(_ document: ConfigDocument, userId: String, platform: String?) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for param in document.params {
            if let value = resolve(param, userId: userId, platform: platform) { out[param.k] = value }
        }
        return out
    }

    /// The variant a person gets: the first whose upper bound is above the person's bucket.
    static func assign(_ experiment: CompiledExperiment, userId: String) -> Assignment? {
        let bucket = Bucketing.bucket(key: "ab:\(experiment.k):\(experiment.s)", userId: userId)
        guard let index = experiment.v.firstIndex(where: { bucket < $0.b }) else { return nil }
        let variant = experiment.v[index]
        return Assignment(variant: variant.n, index: index, value: variant.v)
    }
}

// Optional means absent, not JSON null. Match the other SDKs instead of silently erasing malformed fields.
extension CompiledParam {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(k: try c.decode(String.self, forKey: .k),
                  t: c.contains(.t) ? try c.decode(String.self, forKey: .t) : nil,
                  v: try c.decode(JSONValue.self, forKey: .v), r: try c.decode(Int.self, forKey: .r),
                  o: c.contains(.o) ? try c.decode([String: JSONValue].self, forKey: .o) : nil)
    }
}
extension CompiledExperiment {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(k: try c.decode(String.self, forKey: .k), s: try c.decode(String.self, forKey: .s),
                  p: c.contains(.p) ? try c.decode(String.self, forKey: .p) : nil,
                  v: try c.decode([CompiledVariant].self, forKey: .v))
    }
}
extension ConfigDocument {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try c.decode(Int.self, forKey: .version), etag: try c.decode(String.self, forKey: .etag),
                  params: try c.decode([CompiledParam].self, forKey: .params),
                  experiments: c.contains(.experiments) ? try c.decode([CompiledExperiment].self, forKey: .experiments) : nil)
    }
}
