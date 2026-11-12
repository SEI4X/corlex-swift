import XCTest
@testable import corlex_symtab

final class ParserTests: XCTestCase {
    func testLineParserReadsFilesDirectoriesAndRows() {
        let text = """
        debug_line[0x00000000]
        Line table prologue:
         version: 4
        include_directories[  1] = "/src/App"
        file_names[  1]:
                   name: "Paywall.swift"
              dir_index: 1
               mod_time: 0x00000000
        file_names[  2]:
                   name: "/abs/Other.swift"
              dir_index: 0
        file_names[  3]:
                   name: "rel.swift"
              dir_index: 0

        Address            Line   Column File   ISA Discriminator OpIndex Flags
        ------------------ ------ ------ ------ --- ------------- ------- -------------
        0x0000000100003f40      7      5      1   0             0       0  is_stmt prologue_end
        0x0000000100003f48      9      0      2   0             0       0
        0x0000000100003f50      1      0      3   0             0       0  is_stmt end_sequence
        """
        var rows: [LineRow] = []
        let parser = DwarfLineParser { rows.append($0) }
        text.split(separator: "\n", omittingEmptySubsequences: false).forEach { parser.consume(String($0)) }
        XCTAssertEqual(rows, [
            LineRow(address: 0x1_0000_3f40, path: "/src/App/Paywall.swift", line: 7, isEndOfSequence: false),
            LineRow(address: 0x1_0000_3f48, path: "/abs/Other.swift", line: 9, isEndOfSequence: false),
            LineRow(address: 0x1_0000_3f50, path: "rel.swift", line: 1, isEndOfSequence: true),
        ])
    }

    func testTablesDoNotShareFileNumbers() {
        var rows: [LineRow] = []
        let parser = DwarfLineParser { rows.append($0) }
        for name in ["A.swift", "B.swift"] {
            """
            debug_line[0x0]
            file_names[  1]:
                       name: "\(name)"
                  dir_index: 0
            0x0000000100000010      3      0      1   0             0       0  is_stmt
            """.split(separator: "\n").forEach { parser.consume(String($0)) }
        }
        XCTAssertEqual(rows.map(\.path), ["A.swift", "B.swift"])
    }

    func testMachOInfoParsing() throws {
        let uuids = MachOInfo.parseUUIDs("""
        UUID: 356E350C-730E-3154-ACDD-4DBE4DA26ACD (arm64) App.dSYM/Contents/Resources/DWARF/App
        UUID: 11111111-2222-3333-4444-555555555555 (x86_64) App.dSYM/Contents/Resources/DWARF/App
        """)
        XCTAssertEqual(uuids.map(\.arch), ["arm64", "x86_64"])
        XCTAssertEqual(uuids[0].debugId, "356e350c-730e-3154-acdd-4dbe4da26acd")
        let (base, end) = try MachOInfo.parseSegments("""
        Load command 1
              cmd LC_SEGMENT_64
          segname __TEXT
           vmaddr 0x0000000100000000
           vmsize 0x0000000000004000
        Section
          sectname __text
           segname __TEXT
              addr 0x0000000100000b50
              size 0x000000000000219c
        Section
          sectname __stubs
           segname __TEXT
              addr 0x0000000100002cec
              size 0x0000000000000010
        """)
        XCTAssertEqual(base, 0x1_0000_0000)
        XCTAssertEqual(end, 0x1_0000_0b50 + 0x219c)
    }

    func testFunctionsGetSizesFromTheNextSymbolAndAliasesCollapse() {
        let symbols = FunctionReader.parse("""
        0000000100000000 T __mh_execute_header
        0000000100000b50 t _$s3app4workyS2iF
        0000000100000b50 t _alias_of_work
        0000000100000c00 T _main
                         U _printf
        0000000100003360 s _symbolic _____ 3app7GreeterV
        """)
        XCTAssertEqual(symbols.map(\.name), ["_$s3app4workyS2iF", "_alias_of_work", "_main"], "the Mach-O header is not a function")
        let functions = FunctionReader.functions(
            from: symbols, textBase: 0x1_0000_0000, textEnd: 0x1_0000_0d00, names: symbols.map(\.name)
        )
        XCTAssertEqual(functions.map(\.start), [0xb50, 0xc00])
        XCTAssertEqual(functions.map(\.size), [0xb0, 0x100])
        XCTAssertEqual(functions[0].name, "_$s3app4workyS2iF")
    }

    func testSwiftNamesAreDemangled() {
        let names = FunctionReader.demangled(["_$s3app4workyS2iF", "_main", "__ZN5swift9AsyncTask10waitFutureEv"])
        XCTAssertTrue(names[0].contains("work"), names[0])
        XCTAssertFalse(names[0].contains("$s"), names[0])
        XCTAssertEqual(names[1], "main")
        XCTAssertTrue(names[2].contains("swift::AsyncTask::waitFuture"), names[2])
    }

    func testLineEntriesMergeNeighboursAndEndSequences() {
        let rows = [
            LineRow(address: 0x1_0000_0010, path: "/Users/anna/Dev/App/A.swift", line: 5, isEndOfSequence: false),
            LineRow(address: 0x1_0000_0014, path: "/Users/anna/Dev/App/A.swift", line: 5, isEndOfSequence: false),
            LineRow(address: 0x1_0000_0018, path: "/Users/anna/Dev/App/A.swift", line: 6, isEndOfSequence: false),
            LineRow(address: 0x1_0000_0020, path: "/Users/anna/Dev/App/A.swift", line: 9, isEndOfSequence: true),
            LineRow(address: 0x1_0000_0020, path: "/Users/anna/Dev/App/B.swift", line: 2, isEndOfSequence: false),
            LineRow(address: 0x1_0000_0024, path: "/Users/anna/Dev/App/B.swift", line: 0, isEndOfSequence: false),
            LineRow(address: 0x0, path: "/lower/than/base.swift", line: 1, isEndOfSequence: false),
        ]
        let (files, lines) = SymtabBuilder().lineEntries(rows, textBase: 0x1_0000_0000)
        XCTAssertEqual(files, ["~/Dev/App/A.swift", "~/Dev/App/B.swift"], "the person's name is not kept")
        XCTAssertEqual(lines, [
            .init(start: 0x10, file: 0, line: 5),
            .init(start: 0x18, file: 0, line: 6),
            .init(start: 0x20, file: 1, line: 2),
            .init(start: 0x24, file: 0, line: 0),
        ])
    }

    func testScrubberStripsSymlinkedProjectRoot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("real")
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let source = real.appendingPathComponent("A.swift")
        try Data().write(to: source)
        XCTAssertEqual(PathScrubber(stripPrefixes: [alias.path]).scrub(source.path), "A.swift")
        XCTAssertEqual(PathScrubber(stripPrefixes: [real.path]).scrub(alias.appendingPathComponent("A.swift").path), "A.swift")
        XCTAssertEqual(PathScrubber(stripPrefixes: [real.path]).scrub(real.path + "-other/A.swift"), real.path + "-other/A.swift")
    }

    func testScrubberStripsProjectRootThenHome() {
        let scrubber = PathScrubber(stripPrefixes: ["/Users/anna/Dev/App", "/Users/anna/Dev"])
        XCTAssertEqual(scrubber.scrub("/Users/anna/Dev/App/Sources/A.swift"), "Sources/A.swift")
        XCTAssertEqual(scrubber.scrub("/Users/anna/Library/Foo.swift"), "~/Library/Foo.swift")
        XCTAssertEqual(scrubber.scrub("/Applications/Xcode.app/x.h"), "/Applications/Xcode.app/x.h")
        XCTAssertEqual(scrubber.scrub("relative.swift"), "relative.swift")
    }

    func testSymtabJSONIsTheContractShape() throws {
        let symtab = Symtab(
            debugId: "356e350c-730e-3154-acdd-4dbe4da26acd", arch: "arm64", image: "MyApp",
            files: ["Sources/A \"q\".swift"], functions: [.init(start: 16, size: 8, name: "A.run() -> ()")],
            lines: [.init(start: 16, file: 0, line: 3)]
        )
        let json = symtab.json()
        XCTAssertTrue(json.hasPrefix(#"{"format":"corlex-symtab","version":1,"debug_id":"356e350c"#))
        XCTAssertTrue(json.contains(#""functions":[[16,8,"A.run() -> ()"]]"#))
        XCTAssertTrue(json.contains(#""lines":[[16,0,3]]"#))
        let reference = try ReferenceSymtab(json: Data(json.utf8))
        XCTAssertEqual(reference.files, ["Sources/A \"q\".swift"])
        XCTAssertEqual(reference.lookup(20), .init(function: "A.run() -> ()", file: "Sources/A \"q\".swift", line: 3))
        XCTAssertNil(reference.lookup(24), "past the end of the function")
        XCTAssertNil(reference.lookup(8), "before the first function")
    }
}
