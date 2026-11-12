import Foundation

/// What the generator needs from the Mach-O file of one architecture of a dSYM.
struct MachOInfo: Equatable {
    var debugId: String
    var arch: String
    /// `vmaddr` of `__TEXT`: the address the image's `mach_header` has before ASLR.
    var textBase: UInt64
    /// End of the `__text` section: where the last function stops.
    var textEnd: UInt64

    /// `dwarfdump --uuid` prints `UUID: 356E350C-… (arm64) path` for every architecture.
    static func uuids(of dwarfFile: String) throws -> [(arch: String, debugId: String)] {
        let text = try ProcessRunner.output("dwarfdump", ["--uuid", dwarfFile])
        return parseUUIDs(text)
    }

    static func parseUUIDs(_ text: String) -> [(arch: String, debugId: String)] {
        text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("UUID: "), let open = line.firstIndex(of: "("),
                  let close = line.firstIndex(of: ")") else { return nil }
            let id = line.dropFirst(6).prefix { $0 != " " }
            return (String(line[line.index(after: open)..<close]), id.lowercased())
        }
    }

    static func read(dwarfFile: String, arch: String, debugId: String) throws -> MachOInfo {
        let text = try ProcessRunner.output("otool", ["-arch", arch, "-l", dwarfFile])
        let (base, end) = try parseSegments(text)
        return MachOInfo(debugId: debugId, arch: arch, textBase: base, textEnd: end)
    }

    /// From `otool -l`: the `vmaddr` of segment `__TEXT` and the end of section `__text`.
    static func parseSegments(_ text: String) throws -> (base: UInt64, end: UInt64) {
        var base: UInt64?
        var end: UInt64?
        var segment = ""
        var section = ""
        var address: UInt64 = 0
        for raw in text.split(separator: "\n") {
            let words = raw.split(separator: " ")
            guard words.count >= 2 else { continue }
            switch words[0] {
            case "segname": segment = String(words[1])
            case "sectname": section = String(words[1])
            case "vmaddr" where segment == "__TEXT" && base == nil: base = hex(words[1])
            case "addr": address = hex(words[1]) ?? 0
            case "size" where section == "__text" && segment == "__TEXT" && end == nil:
                end = address + (hex(words[1]) ?? 0)
            default: break
            }
        }
        guard let base, let end else { throw ToolError(description: "no __TEXT segment in the file") }
        return (base, end)
    }

    private static func hex(_ word: Substring) -> UInt64? {
        UInt64(word.dropFirst(2), radix: 16)
    }
}
