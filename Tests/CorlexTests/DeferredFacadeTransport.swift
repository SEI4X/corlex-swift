import XCTest
@testable import Corlex

/// Explicitly separates the fallback read from delivery of the first config document.
final class DeferredFacadeTransport: Transport {
    private let events = StubTransport()
    private let lock = NSLock()
    private var configReply: ((TransportResult) -> Void)?

    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) {
        guard request.url?.path == "/v1/config/document" else { return events.send(request, completion: completion) }
        lock.lock()
        configReply = completion
        lock.unlock()
    }

    var hasPendingConfig: Bool {
        lock.lock()
        defer { lock.unlock() }
        return configReply != nil
    }

    func deliverConfig(_ result: TransportResult, file: StaticString = #filePath, line: UInt = #line) {
        lock.lock()
        let reply = configReply
        configReply = nil
        lock.unlock()
        XCTAssertNotNil(reply, "the first config request must be pending", file: file, line: line)
        reply?(result)
    }

    func sentNames() -> [String] { events.sentNames() }
}
