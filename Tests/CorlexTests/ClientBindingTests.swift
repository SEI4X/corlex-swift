import XCTest
@testable import Corlex

final class ClientBindingTests: XCTestCase {
    private var root: URL!
    private var legacy: Storage!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-binding-\(UUID().uuidString)")
        legacy = Storage(directory: root)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func binding(_ owner: String = "a", _ requested: PrivacyRecord.State = .granted) -> ClientBinding {
        ClientBinding(owner: String(repeating: owner, count: 64), legacy: legacy, requested: requested)
    }

    func testDifferentOwnerCannotReadAnotherHistoryButSameOwnerRestarts() {
        let a = binding()
        a.storage?.writeText("a_identity", to: "anonymous_id")
        a.storage?.writeText("old_event", to: "queue.jsonl")
        let b = binding("b")
        XCTAssertNil(b.storage?.readText("anonymous_id"))
        XCTAssertNil(b.storage?.readText("queue.jsonl"))
        let again = binding()
        XCTAssertEqual(again.storage?.readText("anonymous_id"), "a_identity")
        XCTAssertEqual(again.storage?.readText("queue.jsonl"), "old_event")
        b.revoke()
        XCTAssertFalse(a.canSend)
        XCTAssertFalse(again.isCurrent)
        XCTAssertFalse(b.grant())
        XCTAssertNil(b.storage?.readText("queue.jsonl"))
        XCTAssertFalse(a.grant())
        XCTAssertNil(a.storage?.readText("anonymous_id"))
    }

    func testFreshOwnerPendingDoesNotInheritAnEarlierOwnerGrant() {
        let a = binding()
        XCTAssertTrue(a.canSend)
        let pending = binding("b", .pending)
        XCTAssertEqual(pending.state, .pending)
        XCTAssertFalse(pending.canSend)
        XCTAssertTrue(pending.isCurrent)
        XCTAssertTrue(pending.grant())
        XCTAssertTrue(pending.canSend)
    }

    func testSameOwnerDefaultGrantDoesNotOverrideLaterPendingButExplicitGrantDoes() {
        let original = binding()
        XCTAssertTrue(original.canSend)
        let pending = binding("a", .pending)
        XCTAssertEqual(pending.state, .pending)
        XCTAssertFalse(pending.canSend)
        _ = pending.grant()
        let remembered = binding("a", .pending)
        XCTAssertEqual(remembered.state, .granted)
        XCTAssertTrue(remembered.canSend)
    }

    func testLegacyUnboundStateIsDiscardedButHostFileAndDenialRemain() {
        for name in ["anonymous_id", "user_id", "queue.jsonl", "config.json"] { legacy.writeText("old", to: name) }
        legacy.writeText("host", to: "host.txt")
        legacy.writeText("denied", to: "consent")
        let denied = binding()
        XCTAssertEqual(denied.state, .denied)
        XCTAssertFalse(denied.canSend)
        for name in ["anonymous_id", "user_id", "queue.jsonl", "config.json", "consent"] { XCTAssertNil(legacy.readText(name)) }
        XCTAssertEqual(legacy.readText("host.txt"), "host")
    }

    func testUnknownPrivacyNeedsExplicitFreshMemoryGrantAndLaterDenialStillFencesIt() throws {
        let sdkRoot = root.appendingPathComponent("sdk-ios")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("unavailable directory".utf8).write(to: sdkRoot)
        let a = binding()
        XCTAssertEqual(a.state, .pending)
        XCTAssertFalse(a.canSend)
        XCTAssertNil(a.storage)
        XCTAssertFalse(a.grant())
        XCTAssertTrue(a.canSend)
        XCTAssertNil(a.storage)
        binding("b").revoke()
        XCTAssertFalse(a.canSend)
        XCTAssertFalse(a.grant())
        XCTAssertTrue(a.canSend)
    }

    func testOldResponseCannotApplyToFreshRegrantOrResumeAfterDestroy() {
        final class Deferred: Transport {
            var reply: ((TransportResult) -> Void)?
            func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) { reply = completion }
        }
        let a = binding(), base = Deferred()
        let transport = BoundTransport(base: base, binding: a)
        var rejected = false
        transport.send(URLRequest(url: URL(string: "https://ingest.example.test/v1/batch")!)) { result in
            if case .failure = result { rejected = true } else { XCTFail("obsolete HTTP result applied") }
        }
        a.revoke()
        _ = a.grant()
        base.reply?(.response(status: 401, retryAfter: nil, body: Data()))
        XCTAssertTrue(rejected)
        a.invalidate()
        XCTAssertFalse(a.canSend)
        XCTAssertNil(a.storage)
    }

    func testQueuedOldCleanupPreservesAnotherOwnersFreshExplicitGrantAndFiles() throws {
        let a = binding()
        let expected = a.beginRevocation()
        let b = binding("b")
        _ = b.grant()
        b.storage?.writeText("fresh", to: "queue.jsonl")
        let fresh = try XCTUnwrap(b.storage?.scope?.record)
        a.completeRevocation(expected: expected)
        XCTAssertFalse(a.canSend)
        XCTAssertTrue(b.canSend)
        XCTAssertEqual(b.storage?.scope?.ledger.current(), fresh)
        XCTAssertEqual(b.storage?.readText("queue.jsonl"), "fresh")
    }

    func testNewerImmediateWithdrawalDuringGrantCannotBeClearedByThatOldGrant() {
        let a = binding("a", .pending)
        _ = a.grant { _ = a.beginRevocation() }
        XCTAssertEqual(a.state, .denied)
        XCTAssertFalse(a.canSend)
    }
}
