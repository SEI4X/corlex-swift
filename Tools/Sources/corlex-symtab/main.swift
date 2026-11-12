import Foundation

// corlex-symtab <App.dSYM> --out <directory> [--strip-prefix <path>]...
//
// Writes `<debug_id>.symtab.json` (Corlex symtab v1) for every image and architecture in the
// dSYM and prints one line per file: debug_id, arch, image, path (tab separated).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("corlex-symtab: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var dSYM: String?
var output: String?
var prefixes: [String] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--out":
        guard !arguments.isEmpty else { fail("--out needs a directory") }
        output = arguments.removeFirst()
    case "--strip-prefix":
        guard !arguments.isEmpty else { fail("--strip-prefix needs a path") }
        prefixes.append(arguments.removeFirst())
    case "-h", "--help":
        print("usage: corlex-symtab <App.dSYM> --out <directory> [--strip-prefix <path>]...")
        exit(0)
    default:
        dSYM = argument
    }
}
guard let dSYM, let output else { fail("usage: corlex-symtab <App.dSYM> --out <directory>") }

do {
    let generator = Generator(outputDirectory: URL(fileURLWithPath: output), stripPrefixes: prefixes)
    for result in try generator.generate(dSYM: dSYM) {
        print("\(result.debugId)\t\(result.arch)\t\(result.image)\t\(result.path)")
    }
} catch {
    fail("\(error)")
}
