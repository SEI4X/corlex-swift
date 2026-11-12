import XCTest
@testable import Corlex

final class PrivacyLedgerTests: XCTestCase {
    private var folder: URL!
    private var ledger: PrivacyLedger!
    private let ownerA = String(repeating: "a", count: 64)
    private let ownerB = String(repeating: "b", count: 64)

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-ledger-\(UUID().uuidString)")
        ledger = PrivacyLedger(root: folder.appendingPathComponent("sdk-ios"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testScopesAreIsolatedAndSameFenceSurvivesRestart() throws {
        let record = try XCTUnwrap(ledger.prepare(requested: .granted))
        let a = try XCTUnwrap(ledger.scope(owner: ownerA, record: record))
        let b = try XCTUnwrap(ledger.scope(owner: ownerB, record: record))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.path.contains(record.generation))
        XCTAssertEqual(PrivacyLedger(root: ledger.root).prepare(requested: .granted), record)
        XCTAssertNil(ledger.scope(owner: "../escape", record: record))
    }

    func testRevokeFencesAllOldScopesBeforeCleanupAndRegrant() throws {
        let first = try XCTUnwrap(ledger.prepare(requested: .granted))
        let scope = try XCTUnwrap(ledger.scope(owner: ownerA, record: first))
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: scope.appendingPathComponent("queue.jsonl"))
        let host = folder.appendingPathComponent("host.txt")
        try Data("host".utf8).write(to: host)
        let denied = try XCTUnwrap(ledger.revoke())
        XCTAssertEqual(denied.state, .denied)
        XCTAssertNotEqual(denied.generation, first.generation)
        XCTAssertNil(ledger.authorized(record: first) { XCTFail("stale write ran"); return true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: scope.path))
        XCTAssertEqual(try Data(contentsOf: host), Data("host".utf8))
        XCTAssertNil(ledger.grant(expected: first))
        let fresh = try XCTUnwrap(ledger.grant(expected: denied))
        XCTAssertNotEqual(fresh.generation, denied.generation)
        XCTAssertNil(ledger.authorized(record: first) { true })
        XCTAssertEqual(ledger.authorized(record: fresh) { true }, true)
    }

    func testDeniedAndPendingLegacyChoicesSurviveButGrantDoesNotTransfer() throws {
        XCTAssertEqual(ledger.prepare(requested: .granted, legacy: "denied")?.state, .denied)
        XCTAssertEqual(ledger.prepare(requested: .granted)?.state, .denied)
        try FileManager.default.removeItem(at: ledger.root)
        XCTAssertEqual(ledger.prepare(requested: .granted, legacy: "pending")?.state, .pending)
        try FileManager.default.removeItem(at: ledger.root)
        XCTAssertEqual(ledger.prepare(requested: .pending, legacy: "granted")?.state, .pending)
    }

    func testInvalidAndOversizedPrivacyFailClosed() throws {
        _ = ledger.prepare(requested: .denied)
        let file = ledger.root.appendingPathComponent("privacy.json")
        for bytes in [Data("broken".utf8), Data(repeating: 32, count: 257), Data("{\"generation\":\"../escape\",\"state\":\"granted\"}".utf8)] {
            try bytes.write(to: file)
            XCTAssertNil(ledger.current())
            XCTAssertNil(ledger.prepare(requested: .granted))
            XCTAssertNil(ledger.grant(expected: PrivacyRecord(generation: UUID().uuidString, state: .granted)))
        }
    }

    func testTwoLedgerInstancesSerializeRevocationWithDelayedWrite() throws {
        let first = try XCTUnwrap(ledger.prepare(requested: .granted))
        let other = PrivacyLedger(root: ledger.root)
        let admitted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "writer")
        DispatchQueue.global().async {
            _ = other.authorized(record: first) {
                admitted.signal()
                _ = release.wait(timeout: .now() + 3)
            }
            finished.fulfill()
        }
        XCTAssertEqual(admitted.wait(timeout: .now() + 3), .success)
        let revoked = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let owner = ledger!
        DispatchQueue.global().async {
            started.signal()
            _ = owner.revoke()
            revoked.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(revoked.wait(timeout: .now() + 0.03), .timedOut)
        release.signal()
        XCTAssertEqual(revoked.wait(timeout: .now() + 3), .success)
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(ledger.current()?.state, .denied)
        XCTAssertNil(other.authorized(record: first) { true })
    }

    func testFailedDurableRevocationStillFencesOtherInstances() throws {
        let first = try XCTUnwrap(ledger.prepare(requested: .granted))
        let other = PrivacyLedger(root: ledger.root)
        try FileManager.default.removeItem(at: ledger.root)
        try Data("blocks directory".utf8).write(to: ledger.root)
        XCTAssertNil(ledger.revoke())
        XCTAssertEqual(other.current()?.state, .denied)
        XCTAssertNil(other.authorized(record: first) { XCTFail("failed I/O revived old grant"); return true })
        XCTAssertNil(other.prepare(requested: .granted))
    }

    func testDenialPublishedDuringActionCannotExposeItsStaleReadResult() throws {
        let granted = try XCTUnwrap(ledger.prepare(requested: .granted))
        let denied = PrivacyRecord(generation: UUID().uuidString.lowercased(), state: .denied)
        let result = ledger.authorized(record: granted) {
            ledger.setMemoryFence(denied) // nonblocking denial, not disk revoke under its own lock
            return "old captured value"
        }
        XCTAssertNil(result)
        XCTAssertEqual(ledger.current(), denied)
    }

    func testOldPublicationCannotClearNewerInProcessDenial() {
        let older = PrivacyRecord(generation: UUID().uuidString, state: .denied)
        let newer = PrivacyRecord(generation: UUID().uuidString, state: .denied)
        ledger.setMemoryFence(newer)
        ledger.clearMemoryFence(expected: older)
        XCTAssertEqual(ledger.memoryFence(), newer)
        ledger.clearMemoryFence(expected: newer)
        XCTAssertNil(ledger.memoryFence())
    }

    func testSdkRootAndPrivacyAreProtectedAndBackupExcluded() throws {
        _ = try XCTUnwrap(ledger.prepare(requested: .pending))
        for (url, mode) in [(ledger.root, 0o700), (ledger.root.appendingPathComponent("privacy.json"), 0o600)] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode)
        }
    }
}
