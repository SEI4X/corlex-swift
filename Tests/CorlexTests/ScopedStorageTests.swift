import XCTest
@testable import Corlex

final class ScopedStorageTests: XCTestCase {
    private var folder: URL!
    private var ledger: PrivacyLedger!
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-scope-\(UUID().uuidString)")
        ledger = PrivacyLedger(root: folder.appendingPathComponent("sdk-ios"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }
    private func storage(_ owner: String, _ record: PrivacyRecord) throws -> Storage {
        try XCTUnwrap(Storage.bound(scope: StorageScope(ledger: ledger, owner: String(repeating: owner, count: 64), record: record)))
    }

    func testOwnerIsolationAndRestartPreserveOnlyOwnData() throws {
        let record = try XCTUnwrap(ledger.prepare(requested: .granted))
        let a = try storage("a", record), b = try storage("b", record)
        a.writeText("owner-a", to: "anonymous_id")
        a.append(Data("first\n".utf8), to: "queue.jsonl")
        XCTAssertNil(b.readText("anonymous_id"))
        XCTAssertNil(b.readText("queue.jsonl"))
        let restarted = try storage("a", record)
        XCTAssertEqual(restarted.readText("anonymous_id"), "owner-a")
        XCTAssertEqual(restarted.readText("queue.jsonl"), "first\n")
    }

    func testRevocationRejectsDelayedWritesReadsAndRegrantDoesNotReviveOldScopes() throws {
        let record = try XCTUnwrap(ledger.prepare(requested: .granted))
        let a = try storage("a", record), b = try storage("b", record)
        a.writeText("old", to: "anonymous_id")
        let denied = try XCTUnwrap(ledger.revoke())
        let granted = try XCTUnwrap(ledger.grant(expected: denied))
        for stale in [a, b] {
            stale.writeText("late", to: "anonymous_id")
            stale.append(Data("late".utf8), to: "queue.jsonl")
            stale.remove("anything")
            XCTAssertNil(stale.prepare(subfolder: "crashes"))
            XCTAssertNil(stale.readText("anonymous_id"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.directory.path))
        }
        let fresh = try storage("a", granted)
        XCTAssertNil(fresh.readText("anonymous_id"))
        fresh.writeText("new", to: "anonymous_id")
        a.wipe()
        XCTAssertEqual(fresh.readText("anonymous_id"), "new")
    }

    func testPendingStoresNoCapturedDataUntilSameGenerationGrant() throws {
        let pending = try XCTUnwrap(ledger.prepare(requested: .pending))
        let store = try storage("a", pending)
        store.writeText("private", to: "anonymous_id")
        store.append(Data("private".utf8), to: "queue.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        let granted = try XCTUnwrap(ledger.grant(expected: pending))
        XCTAssertTrue(store.scope?.grantSameGeneration(granted) == true)
        store.writeText("consented", to: "anonymous_id")
        XCTAssertEqual(store.readText("anonymous_id"), "consented")
        let denied = try XCTUnwrap(ledger.revoke())
        let fresh = try XCTUnwrap(ledger.grant(expected: denied))
        XCTAssertFalse(store.scope?.grantSameGeneration(fresh) == true)
    }

    func testPathBoundsPermissionsAndSizeAreAppliedToFileOperations() throws {
        let record = try XCTUnwrap(ledger.prepare(requested: .granted))
        let store = try storage("a", record)
        for name in ["../host", "x/y", "..", "x\\y", "x\0y"] {
            store.writeText("private", to: name)
            store.append(Data("private".utf8), to: name)
            XCTAssertNil(store.read(name))
        }
        store.write(Data(repeating: 1, count: 2 * 1024 * 1024 + 1), to: "too-large")
        XCTAssertNil(store.read("too-large"))
        store.writeText("safe", to: "identity")
        XCTAssertEqual(try store.url("identity").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.url("identity").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
