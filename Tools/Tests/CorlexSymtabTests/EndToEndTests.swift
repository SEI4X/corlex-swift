import XCTest
@testable import corlex_symtab

/// Build -> dSYM -> symtab -> look an address up with the reference implementation. The
/// addresses of the functions come from `nm` on the linked binary, not from the generator, so
/// a mistake in the generator cannot hide behind itself.
final class EndToEndTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-symtab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: work)
    }

    /// Compiles the fixture the way Xcode does (object file kept for dsymutil), links, makes a dSYM.
    private func buildFixture() throws -> (binary: String, dSYM: String, source: String) {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let source = work.appendingPathComponent("Paywall.swift")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("Paywall.swift"), to: source)
        let object = work.appendingPathComponent("main.o").path
        let binary = work.appendingPathComponent("Sample").path
        let dSYM = work.appendingPathComponent("Sample.dSYM").path
        _ = try ProcessRunner.output("swiftc", ["-Onone", "-g", "-module-name", "Sample", "-c", "-o", object, source.path])
        _ = try ProcessRunner.output("swiftc", ["-o", binary, object])
        _ = try ProcessRunner.output("dsymutil", ["-o", dSYM, binary])
        return (binary, dSYM, source.path)
    }

    /// `(address - __mh_execute_header, mangled name)` of every text symbol of the linked binary.
    private func binarySymbols(_ binary: String) throws -> [(offset: UInt64, name: String)] {
        let text = try ProcessRunner.output("nm", ["-n", binary])
        var base: UInt64 = 0
        var symbols: [(UInt64, String)] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, let address = UInt64(fields[0], radix: 16) else { continue }
            if fields[2] == "__mh_execute_header" { base = address }
            if fields[1] == "t" || fields[1] == "T" { symbols.append((address, String(fields[2]))) }
        }
        return symbols.map { ($0.0 - base, $0.1) }
    }

    private func line(of marker: String, in source: String) throws -> Int {
        let lines = try String(contentsOfFile: source, encoding: .utf8).components(separatedBy: "\n")
        return try XCTUnwrap(lines.firstIndex { $0.contains(marker) }) + 1
    }

    func testKnownFunctionsMapToTheirNameFileAndLine() throws {
        let built = try buildFixture()
        let generated = try Generator(outputDirectory: work.appendingPathComponent("out"), stripPrefixes: [work.path])
            .generate(dSYM: built.dSYM)
        XCTAssertEqual(generated.count, 1)
        let symtab = try ReferenceSymtab(json: Data(contentsOf: URL(fileURLWithPath: generated[0].path)))
        XCTAssertTrue(symtab.isSorted)
        XCTAssertEqual(symtab.image, "Sample")
        XCTAssertEqual(symtab.arch, DeviceArch.current)
        let expectedDebugId = try XCTUnwrap(MachOInfo.uuids(of: built.binary).first?.debugId)
        XCTAssertEqual(symtab.debugId, expectedDebugId, "the UUID the running image reports in LC_UUID")

        let symbols = try binarySymbols(built.binary)
        let cases: [(mangled: String, demangled: String, marker: String)] = [
            ("discountedPrice", "Paywall.discountedPrice(percent:", "func discountedPrice"),
            ("8headline", "Paywall.headline(for:", "static func headline"),
            ("8checkout", "checkout(total:", "func checkout"),
        ]
        for item in cases {
            let symbol = try XCTUnwrap(symbols.first { $0.name.contains(item.mangled) }, item.mangled)
            let hit = try XCTUnwrap(symtab.lookup(symbol.offset), "no hit for \(item.demangled)")
            XCTAssertTrue(hit.function.contains(item.demangled), hit.function)
            XCTAssertEqual(hit.file, "Paywall.swift")
            XCTAssertEqual(hit.line, try line(of: item.marker, in: built.source), item.demangled)
        }
    }

    func testAnAddressInsideAFunctionBodyMapsToTheBodyLine() throws {
        let built = try buildFixture()
        let generated = try Generator(outputDirectory: work.appendingPathComponent("out")).generate(dSYM: built.dSYM)
        let symtab = try ReferenceSymtab(json: Data(contentsOf: URL(fileURLWithPath: generated[0].path)))
        let symbol = try XCTUnwrap(try binarySymbols(built.binary).first { $0.name.contains("discountedPrice") })
        let body = try line(of: "let discount =", in: built.source)
        let lines = (0..<64).compactMap { symtab.lookup(symbol.offset + UInt64($0) * 4) }.map(\.line)
        XCTAssertTrue(lines.contains(body), "somewhere in the function the body line is reported: \(lines)")
        XCTAssertTrue(lines.contains(body + 1), "and the return line after it")
    }
}

enum DeviceArch {
    static var current: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
