import Foundation

/// A reference implementation of what the server does with a symtab: find the function and the
/// source line of an offset (`addr - image_addr` of a crash frame). Independent of the code that
/// writes the file: it reads the JSON the way a consumer written from the format description would.
struct ReferenceSymtab {
    struct Hit: Equatable {
        var function: String
        var file: String?
        var line: Int
    }

    let debugId: String
    let arch: String
    let image: String
    let files: [String]
    private let functions: [(start: UInt64, size: UInt64, name: String)]
    private let lines: [(start: UInt64, file: Int, line: Int)]

    init(json: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              root["format"] as? String == "corlex-symtab", root["version"] as? Int == 1,
              let debugId = root["debug_id"] as? String, let arch = root["arch"] as? String,
              let image = root["image"] as? String, let files = root["files"] as? [String],
              let functions = root["functions"] as? [[Any]], let lines = root["lines"] as? [[Any]]
        else { throw NSError(domain: "symtab", code: 1) }
        self.debugId = debugId
        self.arch = arch
        self.image = image
        self.files = files
        self.functions = functions.map { (UInt64(truncating: $0[0] as! NSNumber), UInt64(truncating: $0[1] as! NSNumber), $0[2] as! String) }
        self.lines = lines.map { (UInt64(truncating: $0[0] as! NSNumber), ($0[1] as! NSNumber).intValue, ($0[2] as! NSNumber).intValue) }
    }

    /// Both arrays must be sorted by `start`: the contract binary searches them.
    var isSorted: Bool {
        zip(functions, functions.dropFirst()).allSatisfy { $0.start < $1.start }
            && zip(lines, lines.dropFirst()).allSatisfy { $0.start < $1.start }
    }

    func lookup(_ offset: UInt64) -> Hit? {
        guard let function = function(at: offset) else { return nil }
        var low = 0
        var high = lines.count
        while low < high {  // first entry that starts after the offset
            let mid = (low + high) / 2
            if lines[mid].start <= offset { low = mid + 1 } else { high = mid }
        }
        guard low > 0, lines[low - 1].line > 0 else { return Hit(function: function, file: nil, line: 0) }
        let entry = lines[low - 1]
        return Hit(function: function, file: files[entry.file], line: entry.line)
    }

    private func function(at offset: UInt64) -> String? {
        var low = 0
        var high = functions.count
        while low < high {
            let mid = (low + high) / 2
            if functions[mid].start <= offset { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let candidate = functions[low - 1]
        return offset < candidate.start + candidate.size ? candidate.name : nil
    }

    /// The offset of the first function whose name contains `fragment`.
    func start(ofFunctionContaining fragment: String) -> UInt64? {
        functions.first { $0.name.contains(fragment) }?.start
    }
}
