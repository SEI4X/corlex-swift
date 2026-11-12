import Foundation

/// The result for one image and architecture: where the symtab was written.
struct GeneratedSymtab: Equatable {
    var debugId: String
    var arch: String
    var image: String
    var path: String
}

struct Generator {
    var outputDirectory: URL
    var stripPrefixes: [String] = []

    /// A `.dSYM` bundle (or one DWARF file inside it) becomes one symtab per image and architecture.
    func generate(dSYM: String) throws -> [GeneratedSymtab] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var results: [GeneratedSymtab] = []
        for file in try dwarfFiles(in: dSYM) {
            let image = URL(fileURLWithPath: file).lastPathComponent
            for (arch, debugId) in try MachOInfo.uuids(of: file) {
                results.append(try generate(dwarfFile: file, image: image, arch: arch, debugId: debugId))
            }
        }
        if results.isEmpty { throw ToolError(description: "no DWARF file with a UUID in \(dSYM)") }
        return results
    }

    private func generate(dwarfFile: String, image: String, arch: String, debugId: String) throws -> GeneratedSymtab {
        let info = try MachOInfo.read(dwarfFile: dwarfFile, arch: arch, debugId: debugId)
        let symbols = try FunctionReader.symbols(of: dwarfFile, arch: arch)
        let names = FunctionReader.demangled(symbols.map(\.name))
        var rows: [LineRow] = []
        let parser = DwarfLineParser { rows.append($0) }
        try ProcessRunner.stream("dwarfdump", ["--arch=\(arch)", "--debug-line", dwarfFile]) { parser.consume($0) }
        var builder = SymtabBuilder()
        builder.scrubber = PathScrubber(stripPrefixes: stripPrefixes)
        let symtab = builder.build(info: info, image: image, symbols: symbols, names: names, rows: rows)
        let url = outputDirectory.appendingPathComponent("\(debugId).symtab.json")
        try Data(symtab.json().utf8).write(to: url, options: .atomic)
        return GeneratedSymtab(debugId: debugId, arch: arch, image: image, path: url.path)
    }

    private func dwarfFiles(in path: String) throws -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ToolError(description: "\(path) does not exist")
        }
        guard isDirectory.boolValue else { return [path] }
        let folder = path + "/Contents/Resources/DWARF"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.sorted().map { folder + "/" + $0 }
    }
}
