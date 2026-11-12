import XCTest
@testable import Corlex

final class PrivacyCeilingTests: XCTestCase {
    private var folder: URL!
    private var ledger: PrivacyLedger!
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-ceiling-\(UUID().uuidString)")
        ledger = PrivacyLedger(root: folder)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testInitialDeniedCeilingNeverPublishesTransientGrantOrLosesSdkChoice() throws {
        let denied = try XCTUnwrap(ledger.prepare(requested: .granted, ceiling: .denied))
        XCTAssertEqual(denied.state, .denied)
        XCTAssertEqual(denied.sdkChoice, .granted)
        let bytes = try Data(contentsOf: folder.appendingPathComponent("privacy.json"))
        XCTAssertLessThanOrEqual(bytes.count, 256)
        XCTAssertEqual(try JSONDecoder().decode(PrivacyRecord.self, from: bytes), denied)
        let restored = try XCTUnwrap(ledger.observe(expected: denied, ceiling: .granted))
        XCTAssertEqual(restored.state, .granted)
        XCTAssertNotEqual(restored.generation, denied.generation)
    }

    func testCeilingNeverLiftsSdkDeniedOrPending() throws {
        for choice in [PrivacyRecord.State.denied, .pending] {
            try? FileManager.default.removeItem(at: folder)
            let original = try XCTUnwrap(ledger.prepare(requested: choice, ceiling: .denied))
            let restored = try XCTUnwrap(ledger.observe(expected: original, ceiling: .granted))
            XCTAssertEqual(restored.state, choice)
            XCTAssertEqual(restored.sdkChoice, choice)
            XCTAssertNil(ledger.authorized(record: restored) { true })
        }
    }

    func testBothCeilingDirectionsFenceAndWipeBeforeOldScopeCanReturn() throws {
        let original = try XCTUnwrap(ledger.prepare(requested: .granted))
        let scope = try XCTUnwrap(ledger.scope(owner: String(repeating: "a", count: 64), record: original))
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: scope.appendingPathComponent("queue.jsonl"))
        var disabledBeforePublish = false
        let denied = try XCTUnwrap(ledger.observe(expected: original, ceiling: .denied) {
            let onDisk = try? Data(contentsOf: folder.appendingPathComponent("privacy.json"))
            XCTAssertEqual(onDisk.flatMap { try? JSONDecoder().decode(PrivacyRecord.self, from: $0) }, original)
            disabledBeforePublish = true
        })
        XCTAssertTrue(disabledBeforePublish)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scope.path))
        XCTAssertNil(ledger.authorized(record: original) { true })
        let restored = try XCTUnwrap(ledger.observe(expected: denied, ceiling: .granted))
        XCTAssertNotEqual(restored.generation, denied.generation)
        XCTAssertNil(ledger.authorized(record: original) { true })
    }

    func testStaleObserverCannotOverrideFreshSdkDenial() throws {
        let original = try XCTUnwrap(ledger.prepare(requested: .granted))
        let denied = try XCTUnwrap(ledger.revoke())
        XCTAssertNil(ledger.observe(expected: original, ceiling: .granted) { XCTFail("stale callback ran") })
        XCTAssertEqual(ledger.current(), denied)
    }

    func testConcurrentMemoryDenialWinsOverOlderPublication() throws {
        let original = try XCTUnwrap(ledger.prepare(requested: .granted))
        let newest = PrivacyRecord(generation: UUID().uuidString.lowercased(), state: .denied)
        XCTAssertNil(ledger.observe(expected: original, ceiling: .pending) { ledger.setMemoryFence(newest) })
        XCTAssertEqual(ledger.current(), newest)
        XCTAssertEqual(ledger.current()?.sdkChoice, .denied)
    }

    func testOnlySdkPendingGrantPreservesGenerationNotAttRestore() throws {
        let pending = try XCTUnwrap(ledger.prepare(requested: .pending))
        let granted = try XCTUnwrap(ledger.grant(expected: pending))
        XCTAssertEqual(granted.generation, pending.generation)
        let attPending = try XCTUnwrap(ledger.observe(expected: granted, ceiling: .pending))
        let restored = try XCTUnwrap(ledger.grant(expected: attPending, ceiling: .granted))
        XCTAssertNotEqual(restored.generation, attPending.generation)
    }

    func testLegacyFallbackRejectsUnknownExtraFields() throws {
        _ = ledger.prepare(requested: .pending)
        let file = folder.appendingPathComponent("privacy.json")
        let id = UUID().uuidString.lowercased()
        for extra in ["\"extra\":true", "\"sdkChoice\":\"granted\",\"extra\":true"] {
            try Data("{\"generation\":\"\(id)\",\"state\":\"granted\",\(extra)}".utf8).write(to: file)
            XCTAssertNil(ledger.current())
            XCTAssertNil(ledger.prepare(requested: .granted))
        }
    }

    func testLegacyFallbackRequiresAbsentChoiceAndConsistentRestriction() throws {
        _ = ledger.prepare(requested: .pending)
        let id = UUID().uuidString.lowercased()
        let file = folder.appendingPathComponent("privacy.json")
        try Data("{\"generation\":\"\(id)\",\"state\":\"denied\"}".utf8).write(to: file)
        XCTAssertEqual(ledger.current()?.sdkChoice, .denied)
        for suffix in ["null", "\"wrong\"", "\"denied\""] {
            try Data("{\"generation\":\"\(id)\",\"state\":\"granted\",\"sdkChoice\":\(suffix)}".utf8).write(to: file)
            XCTAssertNil(ledger.current())
            XCTAssertNil(ledger.prepare(requested: .granted))
        }
    }
}
