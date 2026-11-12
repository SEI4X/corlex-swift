import XCTest
@testable import Corlex

private final class TrackingBox {
    private let lock = NSLock()
    private var stored: CorlexConsent = .granted
    var value: CorlexConsent {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class AttBindingTests: XCTestCase {
    private var folder: URL!
    private var clients: [CorlexClient] = []
    private let tracking = TrackingBox()
    override func setUp() { folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-att-binding-\(UUID().uuidString)") }
    override func tearDown() {
        for client in clients { client.stop(); client.queue.sync {} }
        try? FileManager.default.removeItem(at: folder)
    }
    private func make(_ mode: CorlexStartConsent = .att, appOpen: Bool = false) throws -> (CorlexClient, StubTransport) {
        let transport = StubTransport()
        var options = Harness.fastOptions()
        options.consent = mode
        options.config.enabled = false
        options.autocapture.appOpen = appOpen
        options.flushInterval = 60
        let env = ClientEnvironment(storage: Storage(directory: folder), transport: transport, device: testDevice,
            trackingStatus: { [tracking] in tracking.value }, now: Date.init, installGlobalHooks: false,
            backoff: Backoff(base: 60, maximum: 60, random: { 0 }))
        let client = try XCTUnwrap(CorlexClient(key: testSDKKey, options: options, env: env))
        clients.append(client)
        client.queue.sync {}
        return (client, transport)
    }
    private func flush(_ client: CorlexClient) {
        let done = expectation(description: "flush")
        client.flush { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    func testExplicitSdkOptOutIsNeverLiftedByRestoredAtt() throws {
        let (client, transport) = try make()
        client.optOut(); client.queue.sync {}
        tracking.value = .denied
        _ = client.configValues()
        tracking.value = .granted
        client.track("must_stay_denied")
        flush(client)
        XCTAssertEqual(client.currentConsent(), .denied)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRestoredAttCannotLiftPersistedSdkPending() throws {
        let (pending, _) = try make(.pending)
        pending.stop(); pending.queue.sync {}
        tracking.value = .denied
        let (client, transport) = try make()
        XCTAssertEqual(client.currentConsent(), .denied)
        tracking.value = .granted
        client.track("sdk_pending")
        flush(client)
        XCTAssertEqual(client.currentConsent(), .pending)
        XCTAssertTrue(transport.requests.isEmpty)
        client.optIn()
        flush(client)
        XCTAssertEqual(transport.sentNames(), ["sdk_pending"])
    }

    func testCeilingTighteningStopsRequestTimeDeliveryAndRestoreStartsFresh() throws {
        let (client, transport) = try make()
        transport.responder = { _ in StubTransport.ok(503) }
        client.track("before_att_denial")
        flush(client)
        let old = try XCTUnwrap(transport.sentEvents.first?["anonymous_id"] as? String)
        let previousCount = transport.requests.count
        tracking.value = .denied
        client.track("blocked")
        flush(client)
        XCTAssertEqual(transport.requests.count, previousCount)
        XCTAssertEqual(client.currentConsent(), .denied)
        tracking.value = .granted
        transport.responder = { _ in StubTransport.ok(202) }
        client.track("fresh")
        flush(client)
        XCTAssertEqual(transport.sentNames(), ["before_att_denial", "fresh"])
        XCTAssertNotEqual(transport.sentEvents.last?["anonymous_id"] as? String, old)
    }

    func testInitiallyDeniedAttCanRestoreSdkGrantAndEmitOneFreshOpen() throws {
        tracking.value = .denied
        let (client, transport) = try make(appOpen: true)
        XCTAssertEqual(client.currentConsent(), .denied)
        tracking.value = .granted
        _ = client.configValues() // a public config read observes the live ceiling
        flush(client)
        XCTAssertEqual(client.currentConsent(), .granted)
        XCTAssertEqual(transport.sentNames(), ["app_open"])
        _ = client.configValues()
        flush(client)
        XCTAssertEqual(transport.sentNames(), ["app_open"])
    }
}
