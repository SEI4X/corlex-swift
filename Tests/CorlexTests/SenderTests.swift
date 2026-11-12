import XCTest
@testable import Corlex

final class SenderTests: XCTestCase {
    private let dispatch = DispatchQueue(label: "sender-tests")
    private var transport: StubTransport!
    private var queue: EventQueue!
    private var sender: Sender!

    override func setUp() {
        transport = StubTransport()
        queue = EventQueue(storage: nil, persisted: false)
        makeSender()
    }

    private func makeSender(batchSize: Int = 3, flushInterval: TimeInterval = 0.05,
                            backoff: Backoff = Backoff(base: 0.01, maximum: 0.04, random: { 0 })) {
        var config = Sender.Config(endpoint: URL(string: "https://ingest.test")!, key: "ck_test_secret")
        config.batchSize = batchSize
        config.flushInterval = flushInterval
        config.backoff = backoff
        sender = Sender(queue: queue, transport: transport, config: config, dispatch: dispatch, log: { _ in })
    }

    private func add(_ count: Int) {
        dispatch.sync {
            for index in 0..<count {
                queue.push(WireEvent(
                    eventId: "e\(index)", name: "tap", timestamp: "2026-10-20T11:59:00.250Z", userId: nil,
                    anonymousId: "a_1", properties: [:], context: WireContext()
                ))
            }
        }
    }

    private func flush() {
        let done = expectation(description: "flush")
        dispatch.async { self.sender.flush { done.fulfill() } }
        wait(for: [done], timeout: 3)
    }

    private var queued: Int { dispatch.sync { queue.count } }

    func testRequestShape() throws {
        add(1)
        flush()
        let request = try XCTUnwrap(transport.batches.first)
        XCTAssertEqual(request.url?.absoluteString, "https://ingest.test/v1/batch")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Corlex-Key"), "ck_test_secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(request.url?.absoluteString.contains("ck_test") ?? true, "the key never goes in a URL")
        XCTAssertEqual(queued, 0)
    }

    func testBatchesAreCutAtBatchSize() {
        add(7)
        flush()
        XCTAssertEqual(transport.batches.count, 3)
        XCTAssertEqual(transport.sentEvents.count, 7)
    }

    func testServerErrorKeepsTheEventsAndRetriesWithTheSameIds() {
        // This case drives retries manually; a real 5ms timer races loaded simulator/XCTest scheduling.
        makeSender(backoff: Backoff(base: 60, maximum: 60, random: { 0 }))
        var first = true
        transport.responder = { _ in
            defer { first = false }
            return first ? StubTransport.ok(503) : StubTransport.ok(202)
        }
        add(2)
        flush()
        XCTAssertEqual(queued, 2, "nothing is lost on a 503")
        // Drive the retry ourselves: waiting for asyncAfter on a private queue flakes on CI
        // simulators (600s IDETestOperationsObserver hangs). flush() cancels backoff and resends.
        flush()
        XCTAssertEqual(queued, 0)
        let ids = transport.sentEvents.compactMap { $0["event_id"] as? String }
        XCTAssertEqual(ids, ["e0", "e1", "e0", "e1"])
    }

    func testNetworkFailureRetries() {
        var calls = 0
        transport.responder = { _ in
            calls += 1
            return calls < 3 ? .failure : StubTransport.ok(202)
        }
        add(1)
        flush()
        flush()
        flush()
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(calls, 3)
    }

    func testRateLimitWaitsForRetryAfter() {
        var times: [Date] = []
        transport.responder = { _ in
            times.append(Date())
            return times.count == 1 ? StubTransport.ok(429, retryAfter: "1") : StubTransport.ok(202)
        }
        add(1)
        flush()
        wait(timeout: 4, for: { self.queued == 0 })
        XCTAssertEqual(times.count, 2)
        XCTAssertGreaterThanOrEqual(times[1].timeIntervalSince(times[0]), 0.95)
    }

    func testClientErrorsDropTheBatch() {
        transport.responder = { _ in StubTransport.ok(400, body: #"{"error":"no_valid_events"}"#) }
        add(2)
        flush()
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(transport.batches.count, 1, "a 4xx is not retried")
    }

    func testTooLargeBatchIsSplit() {
        transport.responder = { request in
            let count = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
                .flatMap { ($0["events"] as? [Any])?.count } ?? 0
            return count > 1 ? StubTransport.ok(413) : StubTransport.ok(202)
        }
        add(3)
        flush()
        XCTAssertEqual(queued, 0)
    }

    func testRejectedKeyStopsSendingAndClearsTheQueue() {
        transport.responder = { _ in StubTransport.ok(401) }
        add(2)
        flush()
        XCTAssertEqual(queued, 0)
        add(1)
        dispatch.sync { sender.schedule() }
        flush()
        XCTAssertEqual(transport.batches.count, 1, "no more requests with a rejected key")
    }

    func testAFullBatchGoesAtOnceAndAPartialOneAfterTheInterval() {
        makeSender(batchSize: 3, flushInterval: 0.2)
        add(3)
        dispatch.sync { sender.schedule() }
        wait(timeout: 1, for: { self.transport.batches.count == 1 })
        add(1)
        dispatch.sync { sender.schedule() }
        XCTAssertEqual(transport.batches.count, 1, "a partial batch waits")
        wait(timeout: 2, for: { self.transport.batches.count == 2 })
    }

    func testStoppedSenderSendsNothing() {
        add(1)
        dispatch.sync { sender.stop() }
        flush()
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testBackoffGrowsAndIsCapped() {
        let backoff = Backoff(base: 1, maximum: 60, random: { 0 })
        XCTAssertEqual(backoff.delay(attempt: 1), 0.5)
        XCTAssertEqual(backoff.delay(attempt: 3), 2)
        XCTAssertEqual(backoff.delay(attempt: 30), 30)
        XCTAssertEqual(Backoff(base: 1, maximum: 60, random: { 1 }).delay(attempt: 1), 1)
        XCTAssertEqual(Backoff.retryAfter("7"), 7)
        XCTAssertEqual(Backoff.retryAfter("99999"), 300)
        XCTAssertNil(Backoff.retryAfter("Wed, 21 Oct 2026 07:28:00 GMT"))
    }
}
