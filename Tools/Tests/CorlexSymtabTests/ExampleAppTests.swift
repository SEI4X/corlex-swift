import XCTest
@testable import corlex_symtab

/// The real thing: the example app built for Release, the way a developer ships it, its dSYM
/// turned into a symtab, and addresses of known functions looked up with the reference lookup.
final class ExampleAppTests: XCTestCase {
    private let example = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Example")

    func testReleaseBuildSymtabMapsCrashLabFunctionsToTheirSourceLines() throws {
        let derived = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-example-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: derived) }
        _ = try ProcessRunner.output("xcodebuild", [
            "-project", example.appendingPathComponent("CorlexExample.xcodeproj").path,
            "-scheme", "CorlexExample", "-configuration", "Release", "-sdk", "iphonesimulator",
            "-arch", "arm64", "ONLY_ACTIVE_ARCH=NO", "CORLEX_UPLOAD_SYMBOLS=0",
            "-derivedDataPath", derived.path, "build",
        ])
        let products = derived.appendingPathComponent("Build/Products/Release-iphonesimulator")
        let binary = products.appendingPathComponent("CorlexExample.app/CorlexExample").path
        let dSYM = products.appendingPathComponent("CorlexExample.app.dSYM").path

        let generated = try Generator(outputDirectory: derived.appendingPathComponent("symtab"), stripPrefixes: [example.path])
            .generate(dSYM: dSYM)
        let table = try XCTUnwrap(generated.first { $0.arch == "arm64" })
        let symtab = try ReferenceSymtab(json: Data(contentsOf: URL(fileURLWithPath: table.path)))
        XCTAssertTrue(symtab.isSorted)
        XCTAssertEqual(symtab.debugId, try XCTUnwrap(MachOInfo.uuids(of: binary).first { $0.arch == "arm64" }).debugId)

        // Addresses from the linked binary itself.
        let nm = try ProcessRunner.output("nm", ["-n", "-arch", "arm64", binary])
        var base: UInt64 = 0
        var symbols: [(offset: UInt64, name: String)] = []
        for line in nm.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, let address = UInt64(fields[0], radix: 16) else { continue }
            if fields[2] == "__mh_execute_header" { base = address }
            if fields[1] == "t" || fields[1] == "T" { symbols.append((address, String(fields[2]))) }
        }
        let source = try String(contentsOf: example.appendingPathComponent("CorlexExample/CrashLab.swift"), encoding: .utf8)
        let sourceLines = source.components(separatedBy: "\n")

        for name in ["segfault", "exception", "level3"] {
            let symbol = try XCTUnwrap(symbols.first { $0.name.contains("CrashLab") && $0.name.contains(name) }, name)
            let hit = try XCTUnwrap(symtab.lookup(symbol.offset - base), name)
            XCTAssertTrue(hit.function.contains("CrashLab.\(name)"), hit.function)
            XCTAssertEqual(hit.file, "CorlexExample/CrashLab.swift")
            let marker = try XCTUnwrap(sourceLines.firstIndex { $0.contains("symtab-marker: \(name)") }) + 1
            XCTAssertTrue((marker...(marker + 12)).contains(hit.line), "\(name): line \(hit.line) is not in the function declared at \(marker)")
        }
    }
}
