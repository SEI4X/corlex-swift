import Foundation

/// One row of a DWARF line table, with the file already turned into a path.
struct LineRow: Equatable {
    var address: UInt64
    var path: String
    var line: Int
    var isEndOfSequence: Bool
}

/// Reads the text `dwarfdump --debug-line` prints: for every compile unit a prologue with
/// `include_directories` and `file_names`, then a table of `0x… line column file …  flags` rows.
/// Feed it line by line; the rows come out as they are parsed.
final class DwarfLineParser {
    private var directories: [Int: String] = [:]
    private var files: [Int: (name: String, dir: Int)] = [:]
    private var pendingFile: Int?
    private var pendingName: String?
    private let emit: (LineRow) -> Void

    init(emit: @escaping (LineRow) -> Void) {
        self.emit = emit
    }

    func consume(_ line: String) {
        if line.hasPrefix("0x") { return row(line) }
        if line.hasPrefix("debug_line[") {
            directories = [:]
            files = [:]
        } else if line.hasPrefix("include_directories[") {
            if let (index, value) = Self.indexed(line, separator: "=") { directories[index] = Self.unquote(value) }
        } else if line.hasPrefix("file_names[") {
            pendingFile = Self.indexed(line, separator: "]")?.0
            pendingName = nil
        } else if let file = pendingFile {
            fileAttribute(line, file: file)
        }
    }

    /// `name:` then `dir_index:` follow a `file_names[ N]:` line.
    private func fileAttribute(_ line: String, file: Int) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("name:") {
            pendingName = Self.unquote(String(trimmed.dropFirst(5)))
        } else if trimmed.hasPrefix("dir_index:"), let name = pendingName {
            files[file] = (name, Int(trimmed.dropFirst(10).trimmingCharacters(in: .whitespaces)) ?? 0)
            pendingFile = nil
        }
    }

    private func row(_ line: String) {
        let columns = line.split(separator: " ", omittingEmptySubsequences: true)
        guard columns.count >= 4, let address = UInt64(columns[0].dropFirst(2), radix: 16),
              let number = Int(columns[1]), let fileIndex = Int(columns[3]) else { return }
        let isEnd = columns.contains("end_sequence")
        emit(LineRow(address: address, path: path(of: fileIndex), line: number, isEndOfSequence: isEnd))
    }

    private func path(of index: Int) -> String {
        guard let file = files[index] else { return "<unknown>" }
        if file.name.hasPrefix("/") { return file.name }
        // Directory 0 is the compilation directory, which the line table does not spell out.
        guard file.dir != 0, let directory = directories[file.dir] else { return file.name }
        return directory.hasSuffix("/") ? directory + file.name : directory + "/" + file.name
    }

    /// `include_directories[  1] = "x"` or `file_names[  2]:` -> (1, `"x"`).
    private static func indexed(_ line: String, separator: Character) -> (Int, String)? {
        guard let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]"),
              let index = Int(line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
        else { return nil }
        let rest = line[line.index(after: close)...]
        guard separator == "=" else { return (index, String(rest)) }
        guard let equals = rest.firstIndex(of: "=") else { return nil }
        return (index, rest[rest.index(after: equals)...].trimmingCharacters(in: .whitespaces))
    }

    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}
