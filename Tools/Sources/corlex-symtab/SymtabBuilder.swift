import Foundation

/// Source paths in the symtab: relative to the project where possible, and never with the name
/// of the person who built the app (`/Users/anna/Dev/App/…` becomes `~/Dev/App/…`).
struct PathScrubber {
    /// Prefixes to cut off, longest first (the project root, `SRCROOT`).
    var stripPrefixes: [String] = []

    func scrub(_ path: String) -> String {
        // Xcode may record /tmp while SRCROOT resolves to /private/tmp (or the reverse).
        // Resolve both sides before comparing; keep the slash so sibling directories never match.
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let prefixes = stripPrefixes.filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            .sorted(by: { $0.count > $1.count })
        for prefix in prefixes {
            let root = prefix.hasSuffix("/") ? prefix : prefix + "/"
            if source.hasPrefix(root) { return String(source.dropFirst(root.count)) }
        }
        for home in ["/Users/", "/home/"] where path.hasPrefix(home) {
            let rest = path.dropFirst(home.count)
            guard let slash = rest.firstIndex(of: "/") else { return path }
            return "~" + rest[slash...]
        }
        return path
    }
}

/// Builds the symtab of one architecture from its function symbols and its line table.
struct SymtabBuilder {
    var scrubber = PathScrubber()

    func build(info: MachOInfo, image: String, symbols: [RawSymbol], names: [String], rows: [LineRow]) -> Symtab {
        let functions = FunctionReader.functions(
            from: symbols, textBase: info.textBase, textEnd: info.textEnd, names: names
        )
        let (files, lines) = lineEntries(rows, textBase: info.textBase)
        return Symtab(
            debugId: info.debugId, arch: info.arch, image: image,
            files: files, functions: functions, lines: lines
        )
    }

    /// Rows -> sorted entries. At one address the last row wins (a real row beats the end of a
    /// sequence that ends there); neighbours with the same file and line are merged; the end of
    /// a sequence becomes line 0, "no source here".
    func lineEntries(_ rows: [LineRow], textBase: UInt64) -> (files: [String], lines: [Symtab.Line]) {
        var fileIndex: [String: Int] = [:]
        var files: [String] = []
        let ordered = rows.enumerated().filter { $0.element.address >= textBase }.sorted {
            let (a, b) = ($0.element, $1.element)
            if a.address != b.address { return a.address < b.address }
            if a.isEndOfSequence != b.isEndOfSequence { return a.isEndOfSequence }
            return $0.offset < $1.offset
        }
        var lines: [Symtab.Line] = []
        for (_, row) in ordered {
            let start = row.address - textBase
            var entry = Symtab.Line(start: start, file: 0, line: 0)
            if !row.isEndOfSequence && row.line > 0 {
                let path = scrubber.scrub(row.path)
                let index = fileIndex[path] ?? files.count
                if fileIndex[path] == nil {
                    fileIndex[path] = index
                    files.append(path)
                }
                entry = Symtab.Line(start: start, file: index, line: row.line)
            }
            if let last = lines.last, last.start == start { lines.removeLast() }
            if let last = lines.last, last.file == entry.file, last.line == entry.line { continue }
            lines.append(entry)
        }
        return (files, lines)
    }
}
