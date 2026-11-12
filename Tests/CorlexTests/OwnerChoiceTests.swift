import XCTest
@testable import Corlex

final class OwnerChoiceTests: XCTestCase {
    private var folder: URL!
    private var clients: [CorlexClient] = []
    private var tracking = CorlexConsent.granted
    override func setUp() { folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-owner-choice-\(UUID().uuidString)") }
    override func tearDown() {
        for client in clients { client.stop(); client.queue.sync {} }
        try? FileManager.default.removeItem(at: folder)
    }
    private func make(_ mode: CorlexStartConsent = .att, owner: String = "a") throws -> (CorlexClient, StubTransport) {
        let transport = StubTransport()
        var options = Harness.fastOptions()
        options.consent = mode; options.config.enabled = false; options.flushInterval = 60
        let env = ClientEnvironment(storage: Storage(directory: folder), transport: transport, device: testDevice,
            trackingStatus: { [unowned self] in self.tracking }, now: Date.init, installGlobalHooks: false,
            backoff: Backoff(base: 60, maximum: 60, random: { 0 }))
        let client = try XCTUnwrap(CorlexClient(key: "ck_test_" + String(repeating: owner, count: 43), options: options, env: env))
        clients.append(client); client.queue.sync {}
        return (client, transport)
    }
    private func stop(_ client: CorlexClient) { client.stop(); client.queue.sync {} }
    private func flush(_ client: CorlexClient) {
        let done = expectation(description: "flush")
        client.flush { done.fulfill() }
        wait(for: [done], timeout: 3)
    }
    private func cycle(_ client: CorlexClient) {
        tracking = .denied; _ = client.configValues()
        XCTAssertEqual(client.currentConsent(), .denied)
        tracking = .granted; _ = client.configValues()
    }

    func testExplicitChoiceSurvivesAttWipesAndLaterPendingRestart() throws {
        let (client, transport) = try make(.pending)
        client.optIn(); client.queue.sync {}
        client.track("before_att"); flush(client)
        let old = try XCTUnwrap(transport.sentEvents.first?["anonymous_id"] as? String)
        stop(client)
        let (att, _) = try make()
        cycle(att); stop(att)
        let (again, next) = try make(.pending)
        XCTAssertEqual(again.currentConsent(), .granted)
        again.track("after_restart"); flush(again)
        XCTAssertEqual(next.sentNames(), ["after_restart"])
        XCTAssertNotEqual(next.sentEvents.first?["anonymous_id"] as? String, old)
    }

    func testRepeatedOptInRemembersOwnerWithoutResettingRuntimeOrCapturedIds() throws {
        let (client, transport) = try make()
        transport.responder = { _ in StubTransport.ok(503) }
        client.track("offline"); flush(client)
        let event = try XCTUnwrap(transport.sentEvents.first)
        let token = client.binding.token
        client.storage?.writeText("retained_config", to: "config.json")
        client.optIn(); client.queue.sync {}
        XCTAssertEqual(client.binding.token, token)
        XCTAssertEqual(client.storage?.readText("config.json"), "retained_config")
        transport.responder = { _ in StubTransport.ok(202) }
        flush(client)
        XCTAssertEqual(transport.sentEvents.last?["event_id"] as? String, event["event_id"] as? String)
        XCTAssertEqual(transport.sentEvents.last?["anonymous_id"] as? String, event["anonymous_id"] as? String)
        cycle(client); stop(client)
        let (again, _) = try make(.pending)
        XCTAssertEqual(again.currentConsent(), .granted)
    }

    func testDefaultGrantAndAttRestorationNeverCreateAnExplicitGrantMarker() throws {
        let (client, _) = try make()
        cycle(client); stop(client)
        let (pending, transport) = try make(.pending)
        XCTAssertEqual(pending.currentConsent(), .pending)
        pending.track("pending"); flush(pending)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testNewPendingOwnerFloorClearsEarlierOwnersExplicitGrant() throws {
        let (a, _) = try make()
        a.optIn(); a.queue.sync {}; stop(a)
        let (b, _) = try make(.pending, owner: "b")
        XCTAssertEqual(b.currentConsent(), .pending)
        b.optIn(); b.queue.sync {}; stop(b)
        let (again, transport) = try make(.pending)
        XCTAssertEqual(again.currentConsent(), .pending)
        again.track("must_remain_pending"); flush(again)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSdkWithdrawalClearsRetainedChoiceDespiteAnotherOwnersLaterGrant() throws {
        let (a, _) = try make()
        a.optIn(); a.queue.sync {}; cycle(a)
        a.optOut(); a.queue.sync {}; stop(a)
        let (b, _) = try make(.granted, owner: "b")
        XCTAssertEqual(b.currentConsent(), .denied)
        b.optIn(); b.queue.sync {}; stop(b)
        let (again, transport) = try make(.pending)
        XCTAssertEqual(again.currentConsent(), .pending)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testExplicitChoiceRemainsKnownAcrossRestartWhileAttIsDenied() throws {
        let (client, _) = try make()
        client.optIn(); client.queue.sync {}
        tracking = .denied; _ = client.configValues(); stop(client)
        let (denied, transport) = try make()
        XCTAssertEqual(denied.currentConsent(), .denied)
        XCTAssertTrue(transport.requests.isEmpty)
        tracking = .granted; _ = denied.configValues(); stop(denied)
        let (again, _) = try make(.pending)
        XCTAssertEqual(again.currentConsent(), .granted)
    }
    func testFailedMarkerCleanupAllowsOnlyFreshMemoryGrantAndNeverDurableOldReplay() throws {
        let (old, oldTransport) = try make()
        oldTransport.responder = { _ in StubTransport.ok(503) }
        old.optIn(); old.queue.sync {}
        old.track("old_offline"); flush(old)
        let previous = try XCTUnwrap(oldTransport.sentEvents.first?["anonymous_id"] as? String)
        stop(old)
        let marker = folder.appendingPathComponent("sdk-ios/owner-choices.json")
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        let (pending, transport) = try make(.pending)
        XCTAssertEqual(pending.currentConsent(), .pending)
        pending.optIn(); pending.queue.sync {}
        XCTAssertEqual(pending.currentConsent(), .granted)
        XCTAssertNil(pending.storage)
        pending.track("fresh_memory"); flush(pending)
        XCTAssertEqual(transport.sentNames(), ["fresh_memory"])
        XCTAssertNotEqual(transport.sentEvents.first?["anonymous_id"] as? String, previous)
        let (again, requests) = try make(.granted, owner: "b")
        XCTAssertEqual(again.currentConsent(), .pending)
        XCTAssertTrue(requests.requests.isEmpty)
    }

    func testPendingFloorImmediatelyFencesAnotherLiveOwnersCapturedHistory() throws {
        let (a, oldTransport) = try make()
        oldTransport.responder = { _ in StubTransport.ok(503) }
        a.optIn(); a.queue.sync {}
        a.track("old_queue"); flush(a)
        let count = oldTransport.requests.count
        let (pending, _) = try make(.pending, owner: "b")
        XCTAssertEqual(pending.currentConsent(), .pending)
        XCTAssertFalse(a.binding.canSend)
        a.track("late_old_instance"); flush(a)
        XCTAssertEqual(oldTransport.requests.count, count)
        pending.optIn(); pending.queue.sync {}
        a.track("old_instance_after_regrant"); flush(a)
        XCTAssertEqual(oldTransport.requests.count, count)
    }

}
