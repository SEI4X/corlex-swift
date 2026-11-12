import Foundation

/// Corlex symtab v1 (docs: services/ingest/docs/protocol.md, "iOS symbol upload"):
///
///     {"format":"corlex-symtab","version":1,"debug_id":"…","arch":"arm64","image":"MyApp",
///      "files":["Sources/App/PaywallView.swift"],
///      "functions":[[start,size,"demangled name"],…],
///      "lines":[[start,fileIndex,line],…]}
///
/// `start` is an offset from the image's `__TEXT` vmaddr, so `addr - image_addr` of a crash
/// frame is looked up directly. Both arrays are sorted by `start`. A `lines` entry holds from
/// its offset until the next entry; `line` 0 means "no source line here".
struct Symtab: Equatable {
    struct Function: Equatable {
        var start: UInt64
        var size: UInt64
        var name: String
    }

    struct Line: Equatable {
        var start: UInt64
        var file: Int
        var line: Int
    }

    var debugId: String
    var arch: String
    var image: String
    var files: [String]
    var functions: [Function]
    var lines: [Line]

    /// The compact JSON text, with the keys in the order above.
    func json() -> String {
        var out = "{\"format\":\"corlex-symtab\",\"version\":1,"
        out += "\"debug_id\":\(Self.quote(debugId)),\"arch\":\(Self.quote(arch)),\"image\":\(Self.quote(image)),"
        out += "\"files\":[" + files.map(Self.quote).joined(separator: ",") + "],"
        out += "\"functions\":["
        out += functions.map { "[\($0.start),\($0.size),\(Self.quote($0.name))]" }.joined(separator: ",")
        out += "],\"lines\":["
        out += lines.map { "[\($0.start),\($0.file),\($0.line)]" }.joined(separator: ",")
        out += "]}"
        return out
    }

    private static func quote(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // JSONEncoder escapes "/" as "\/"; both are valid JSON, the shorter one is easier to read.
        return json.replacingOccurrences(of: "\\/", with: "/")
    }
}
