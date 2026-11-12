import MachO
import XCTest
@testable import Corlex

private let marker: @convention(c) () -> Void = {}

final class CrashReportTests: XCTestCase {
    private var folder: URL!
    private var storage: Storage!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-crash-\(UUID().uuidString)")
        storage = Storage(directory: folder)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - File format

    private let sample = """
    {"v":1,"crash_id":"0192f3a0-0000-7000-8000-000000000001","kind":"native","fatal":true,"arch":"arm64","app_version":"1.4.2","build":"87","os_version":"18.3","source":"signal","name":"SIGSEGV","message":"Signal 11","timestamp_ms":1761004740250}
    F\t3b1f2a60-aaaa-4bbb-8ccc-1234567890ab\t0x100000000\t0x100003f40\tMyApp
    F\t-\t0x0\t0x7ff800001234\t-\tobjc_msgSend
    garbage line
    """

    func testReaderTurnsAFileIntoCrashProperties() throws {
        let crash = try XCTUnwrap(CrashReportReader.parse(Data(sample.utf8)))
        XCTAssertEqual(crash.crashId, "0192f3a0-0000-7000-8000-000000000001")
        XCTAssertEqual(crash.timestamp.timeIntervalSince1970, 1_761_004_740.25, accuracy: 0.001)
        XCTAssertEqual(crash.build, "87")
        XCTAssertEqual(crash.appVersion, "1.4.2")
        let p = crash.properties
        XCTAssertEqual(p["kind"], .string("native"))
        XCTAssertEqual(p["fatal"], .bool(true))
        XCTAssertEqual(p["source"], .string("signal"))
        XCTAssertEqual(p["name"], .string("SIGSEGV"))
        XCTAssertEqual(p["symbolicated"], .bool(false))
        XCTAssertEqual(p["arch"], .string("arm64"))
        XCTAssertEqual(p["frames"], .array([
            .object([
                "image": .string("MyApp"), "debug_id": .string("3b1f2a60-aaaa-4bbb-8ccc-1234567890ab"),
                "image_addr": .string("0x100000000"), "addr": .string("0x100003f40"),
            ]),
            .object(["addr": .string("0x7ff800001234"), "fn": .string("objc_msgSend")]),
        ]))
    }

    func testReaderCapsFramesAndMessageAndRejectsGarbage() throws {
        var text = #"{"crash_id":"0192f3a0-0000-7000-8000-000000000001","timestamp_ms":1,"name":"E","source":"ns_exception","message":""# + String(repeating: "m", count: 900) + "\"}\n"
        for index in 0..<150 { text += "F\t-\t0x0\t0x\(String(index + 16, radix: 16))\t-\n" }
        let crash = try XCTUnwrap(CrashReportReader.parse(Data(text.utf8), captureErrorMessages: true))
        guard case .array(let frames) = crash.properties["frames"] else { return XCTFail() }
        XCTAssertEqual(frames.count, Limits.maxCrashFrames)
        guard case .string(let message) = crash.properties["message"] else { return XCTFail() }
        XCTAssertEqual(message.utf8.count, Limits.maxCrashMessage)
        XCTAssertNil(CrashReportReader.parse(Data("not json".utf8)))
        XCTAssertNil(CrashReportReader.parse(Data()))
    }

    func testPendingReportsAreReadOldestFirstAndDeleted() throws {
        let dir = try XCTUnwrap(storage.prepare(subfolder: CrashReporter.folderName))
        for (id, ms) in [("0192f3a0-0000-7000-8000-000000000002", 2000), ("0192f3a0-0000-7000-8000-000000000001", 1000)] {
            let line = #"{"crash_id":"\#(id)","timestamp_ms":\#(ms),"name":"E","source":"signal","message":"m"}"#
            try Data(line.utf8).write(to: dir.appendingPathComponent("crash-\(id).corlex"))
        }
        try Data("junk".utf8).write(to: dir.appendingPathComponent("crash-bad.corlex"))
        let crashes = CrashReporter.shared.takePending(storage: storage)
        XCTAssertEqual(crashes.map(\.crashId), ["0192f3a0-0000-7000-8000-000000000001", "0192f3a0-0000-7000-8000-000000000002"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testClientSendsAFoundCrashWithItsOriginalTimeIdAndVersion() throws {
        var options = Harness.fastOptions()
        options.autocapture.crashes = true
        let h = Harness(options: options, crashFiles: ["crash-x.corlex": sample], folder: folder)
        defer { h.cleanUp() }
        let dir = h.storage.directory.appendingPathComponent(CrashReporter.folderName)
        wait(for: { !h.transport.sentEvents.isEmpty })
        let event = try XCTUnwrap(h.transport.sentEvents.first)
        XCTAssertEqual(event["name"] as? String, "corlex.crash")
        XCTAssertEqual(event["event_id"] as? String, "0192f3a0-0000-7000-8000-000000000001")
        XCTAssertEqual(event["timestamp"] as? String, "2025-10-20T23:59:00.250Z")
        let properties = try XCTUnwrap(event["properties"] as? [String: Any])
        XCTAssertEqual(properties["crash_id"] as? String, event["event_id"] as? String)
        XCTAssertEqual(properties["build"] as? String, "87")
        XCTAssertEqual((properties["frames"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((event["context"] as? [String: Any])?["os_version"] as? String, "18.3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("crash-x.corlex").path))
    }

    func testNoCrashEventsWithoutConsent() throws {
        var options = Harness.fastOptions()
        options.autocapture.crashes = true
        options.consent = .pending
        let h = Harness(options: options, crashFiles: ["crash-x.corlex": sample], folder: folder)
        defer { h.cleanUp() }
        h.settle()
        XCTAssertTrue(h.transport.requests.isEmpty)
        let file = h.storage.directory.appendingPathComponent("crashes/crash-x.corlex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "bound reports are not read before consent")
    }

    // MARK: - The real handlers

    private func imageUUID(at base: UnsafeRawPointer) -> String? {
        let header = base.assumingMemoryBound(to: mach_header_64.self).pointee
        var cursor = base + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.ncmds {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee
            if command.cmd == UInt32(LC_UUID) {
                let uuid = cursor.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                return UUID(uuid: uuid).uuidString.lowercased()
            }
            cursor += Int(command.cmdsize)
        }
        return nil
    }

    /// Both handlers in one test: the signal handlers are installed once per process.
    func testSignalAndExceptionHandlersWriteFramesWithImageUUIDs() throws {
        // A handler that swallows the signal stands where the app's earlier handler would, so the
        // chain ends here instead of killing the test process.
        var swallow = sigaction()
        swallow.__sigaction_u.__sa_handler = { _ in }
        sigaction(SIGTRAP, &swallow, nil)

        XCTAssertTrue(CrashReporter.shared.install(storage: storage, device: testDevice))
        raise(SIGTRAP)
        var crashes = CrashReporter.shared.takePending(storage: storage)
        let signalCrash = try XCTUnwrap(crashes.first, "the signal handler wrote a report")
        XCTAssertEqual(signalCrash.properties["source"], .string("signal"))
        XCTAssertEqual(signalCrash.properties["name"], .string("SIGTRAP"))
        XCTAssertEqual(signalCrash.appVersion, "1.4.2")
        XCTAssertEqual(signalCrash.build, "87")
        try assertFramesPointIntoThisImage(signalCrash)

        NSSetUncaughtExceptionHandler(nil)  // keep XCTest's own handler out of the chain
        CrashReporter.shared.write(NSException(name: .init("CorlexTestException"), reason: "boom \u{1F4A5} \"quoted\"", userInfo: nil))
        crashes = CrashReporter.shared.takePending(storage: storage)
        XCTAssertTrue(crashes.isEmpty, "fatal admission is terminal; the same process cannot open a second report")
        // Fresh-process NSException writer/privacy coverage lives in Tools/test-crash-writer.sh.
        CrashReporter.shared.disable(deleteReports: true)
    }

    private func assertFramesPointIntoThisImage(_ crash: CapturedCrash) throws {
        var info = Dl_info()
        XCTAssertNotEqual(dladdr(unsafeBitCast(marker, to: UnsafeRawPointer.self), &info), 0)
        let base = try XCTUnwrap(info.dli_fbase)
        let expectedUUID = try XCTUnwrap(imageUUID(at: base))
        let expectedBase = "0x" + String(UInt(bitPattern: base), radix: 16)
        guard case .array(let frames) = crash.properties["frames"] else { return XCTFail("no frames") }
        XCTAssertGreaterThan(frames.count, 3)
        let own = frames.compactMap { frame -> [String: JSONValue]? in
            guard case .object(let fields) = frame, fields["image_addr"] == .string(expectedBase) else { return nil }
            return fields
        }
        XCTAssertFalse(own.isEmpty, "a frame of the test code is in the report")
        for fields in own {
            XCTAssertEqual(fields["debug_id"], .string(expectedUUID), "LC_UUID in 8-4-4-4-12 lowercase")
            guard case .string(let addr) = fields["addr"], let value = UInt(addr.dropFirst(2), radix: 16) else {
                return XCTFail("addr")
            }
            XCTAssertGreaterThan(value, UInt(bitPattern: base))
            XCTAssertNotNil(fields["image"])
        }
    }
}
