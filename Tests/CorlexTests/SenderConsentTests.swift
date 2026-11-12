import Foundation
import XCTest
@testable import Corlex

final class SenderConsentTests: XCTestCase {
    func testOldRejectionCannotClearFreshConsentQueueAndFreshFlushWaitsForDelivery() {
        let dispatch = DispatchQueue(label: "consent-sender-test")
        let queue = EventQueue(storage: nil, persisted: false)
        let transport = DeferredConsentTransport()
        var config = Sender.Config(endpoint: URL(string: "https://ingest.test")!, key: "fake-key")
        config.batchSize = 1
        let sender = Sender(queue: queue, transport: transport, config: config, dispatch: dispatch, log: { _ in })
        let done = expectation(description: "fresh generation delivered")
        dispatch.sync {
            queue.push(event("old"))
            sender.flush()
            sender.stop()
            XCTAssertEqual(transport.pauses, 1)
            queue.clear()
            queue.push(event("new"))
            sender.resume()
            XCTAssertEqual(transport.resumes, 1)
            sender.flush {
                XCTAssertEqual(transport.requests.count, 2)
                XCTAssertEqual(queue.count, 0)
                done.fulfill()
            }
        }
        transport.first?(.response(status: 401, retryAfter: nil, body: Data()))
        wait(for: [done], timeout: 3)
        dispatch.sync { sender.stop() }
    }

    private func event(_ id: String) -> WireEvent {
        WireEvent(eventId: id, name: "opened", timestamp: "2026-11-12T10:00:00Z", userId: nil, anonymousId: "anonymous", properties: [:], context: WireContext())
    }
}

private final class DeferredConsentTransport: Transport {
    var requests: [URLRequest] = []
    var pauses = 0
    var resumes = 0
    func pause() { pauses += 1 }
    func resume() { resumes += 1 }
    var first: ((TransportResult) -> Void)?
    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) {
        requests.append(request)
        if requests.count == 1 { first = completion }
        else { completion(.response(status: 202, retryAfter: nil, body: Data())) }
    }
}
