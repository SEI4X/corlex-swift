import XCTest
@testable import Corlex

final class BindingLifecycleTests: XCTestCase {
    private var folder: URL!
    private var clients: [CorlexClient] = []
    override func setUp() { folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-client-owner-\(UUID().uuidString)") }
    override func tearDown() {
        for client in clients { client.stop(); client.queue.sync {} }
        try? FileManager.default.removeItem(at: folder)
    }
    private func make(_ suffix: String = "a", endpoint: String = "https://ingest.test", pending: Bool = false) throws -> (CorlexClient, StubTransport) {
        let transport = StubTransport()
        var options = Harness.fastOptions()
        options.endpoint = URL(string: endpoint)!
        options.consent = pending ? .pending : .granted
        options.config.enabled = false
        options.flushInterval = 60
        let env = ClientEnvironment(storage: Storage(directory: folder), transport: transport, device: testDevice,
            trackingStatus: { .pending }, now: Date.init, installGlobalHooks: false,
            backoff: Backoff(base: 60, maximum: 60, random: { 0 }))
        let client = try XCTUnwrap(CorlexClient(key: "ck_test_" + String(repeating: suffix, count: 43), options: options, env: env))
        clients.append(client)
        client.queue.sync {}
        return (client, transport)
    }
    private func flush(_ client: CorlexClient) {
        let done = expectation(description: "flush")
        client.flush { done.fulfill() }
        wait(for: [done], timeout: 3)
    }
    private func park(_ client: CorlexClient) { client.queue.sync { client.runtime?.sender.stop(); client.runtime?.remote.stop(wipe: false) } }

    func testOfflineQueueAndIdentityNeverCrossCredentialOrProxyBase() throws {
        let (a, old) = try make()
        old.responder = { _ in StubTransport.ok(503) }
        a.track("owner_a")
        flush(a)
        let original = try XCTUnwrap(old.sentEvents.first?["anonymous_id"] as? String)
        park(a)
        let (b, next) = try make("b")
        b.track("owner_b")
        flush(b)
        XCTAssertEqual(next.sentNames(), ["owner_b"])
        XCTAssertNotEqual(next.sentEvents.first?["anonymous_id"] as? String, original)
        park(b)
        let (proxy, requests) = try make("a", endpoint: "https://ingest.test/cell-b")
        proxy.track("proxy_b")
        flush(proxy)
        let events = requests.requests.flatMap { request -> [[String: Any]] in
            (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["events"] as? [[String: Any]] ?? []
        }
        XCTAssertEqual(events.compactMap { $0["name"] as? String }, ["proxy_b"])
    }

    func testSameOwnerRestartRetainsOriginalOfflineIdsAndIdentity() throws {
        let (a, old) = try make()
        old.responder = { _ in StubTransport.ok(503) }
        a.track("offline")
        flush(a)
        let event = try XCTUnwrap(old.sentEvents.first)
        park(a)
        let (again, next) = try make()
        flush(again)
        XCTAssertEqual(next.sentNames(), ["offline"])
        XCTAssertEqual(next.sentEvents.first?["event_id"] as? String, event["event_id"] as? String)
        XCTAssertEqual(next.sentEvents.first?["anonymous_id"] as? String, event["anonymous_id"] as? String)
    }

    func testOtherOwnerOptOutRegrantCannotReviveOldMemoryOrDiskHistory() throws {
        let (a, old) = try make()
        old.responder = { _ in StubTransport.ok(503) }
        a.track("before_denial")
        flush(a)
        park(a)
        let (b, _) = try make("b")
        b.optOut()
        b.queue.sync {}
        b.optIn()
        b.queue.sync {}
        a.track("late_old_client")
        flush(a)
        let (again, next) = try make()
        again.track("fresh")
        flush(again)
        XCTAssertEqual(next.sentNames(), ["fresh"])
    }

    func testPendingGrantKeepsItsOwnMemoryEventsAndResetKeepsCapturedIdentity() throws {
        let (client, transport) = try make(pending: true)
        client.track("before_reset")
        client.reset()
        client.track("after_reset")
        client.queue.sync {}
        XCTAssertTrue(transport.requests.isEmpty)
        client.optIn()
        flush(client)
        XCTAssertEqual(transport.sentNames(), ["before_reset", "after_reset"])
        XCTAssertNotEqual(transport.sentEvents[0]["anonymous_id"] as? String, transport.sentEvents[1]["anonymous_id"] as? String)
    }

    func testInvalidPublicKeyDoesNothingBeforeATTOrStorage() {
        Corlex.stopForTesting()
        defer { Corlex.stopForTesting() }
        var calls = 0
        let transport = StubTransport()
        let env = ClientEnvironment(storage: Storage(directory: folder), transport: transport, device: testDevice,
            trackingStatus: { calls += 1; return .granted }, now: Date.init, installGlobalHooks: false, backoff: Backoff())
        var options = Harness.fastOptions()
        options.consent = .att
        for key in ["cm_secret", "sk-provider", "ck_test_" + String(repeating: "x", count: 43) + "\n"] {
            Corlex.start(key: key, options: options, environment: env)
            XCTAssertNil(Corlex.client)
        }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
