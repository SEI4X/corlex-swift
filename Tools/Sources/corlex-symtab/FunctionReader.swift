import Foundation

/// A function symbol before sizes and names are settled.
struct RawSymbol: Equatable {
    var address: UInt64
    var name: String
}

/// Function symbols of a dSYM: `nm -n` lists the text symbols (types `T` and `t`) the linker
/// kept in the debug file, with their addresses; a size is the distance to the next symbol, and
/// the last one runs to the end of `__text`. Names are demangled the way `swift demangle
/// --simplified` does (Swift) and `c++filt` (C++).
enum FunctionReader {
    static func symbols(of dwarfFile: String, arch: String) throws -> [RawSymbol] {
        let text = try ProcessRunner.output("nm", ["-n", "-arch", arch, dwarfFile])
        return parse(text)
    }

    /// `0000000100002bf8 t _$s3app4workyS2iF`; the name is everything after the type letter.
    static func parse(_ text: String) -> [RawSymbol] {
        var out: [RawSymbol] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, fields[1] == "t" || fields[1] == "T",
                  let address = UInt64(fields[0], radix: 16), !fields[2].hasPrefix("__mh_") else { continue }
            out.append(RawSymbol(address: address, name: String(fields[2])))
        }
        return out
    }

    static func functions(from symbols: [RawSymbol], textBase: UInt64, textEnd: UInt64, names: [String]) -> [Symtab.Function] {
        var out: [Symtab.Function] = []
        for (index, symbol) in symbols.enumerated() {
            // Several names for one address (aliases): the first one speaks for all of them.
            if index > 0, symbols[index - 1].address == symbol.address { continue }
            let next = symbols[(index + 1)...].first { $0.address > symbol.address }?.address ?? textEnd
            guard symbol.address >= textBase, next > symbol.address else { continue }
            out.append(Symtab.Function(start: symbol.address - textBase, size: next - symbol.address, name: names[index]))
        }
        return out
    }

    /// Demangled names, in the order of `names`. One `swift-demangle` run and one `c++filt` run.
    static func demangled(_ names: [String]) -> [String] {
        let stripped = names.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
        let swiftIndexes = stripped.indices.filter { stripped[$0].hasPrefix("$s") || stripped[$0].hasPrefix("$S") }
        let cppIndexes = stripped.indices.filter { stripped[$0].hasPrefix("_Z") }
        var result = stripped
        run("swift-demangle", ["--simplified"], on: swiftIndexes, in: &result)
        run("c++filt", [], on: cppIndexes, in: &result)
        return result
    }

    private static func run(_ tool: String, _ arguments: [String], on indexes: [Int], in names: inout [String]) {
        guard !indexes.isEmpty else { return }
        let input = indexes.map { names[$0] }.joined(separator: "\n") + "\n"
        guard let output = try? ProcessRunner.output(tool, arguments, stdin: input) else { return }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= indexes.count else { return }
        for (offset, index) in indexes.enumerated() { names[index] = String(lines[offset]) }
    }
}
