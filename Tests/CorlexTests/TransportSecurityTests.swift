#if os(macOS)
import Foundation
import Network
import XCTest
@testable import Corlex

final class TransportSecurityTests: XCTestCase {
    func testPauseCancelsActiveResponseAndBlocksNewWorkUntilResume() throws {
        let started = expectation(description: "server received request")
        let server = try LocalHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nx", closeAfterResponse: false, onRequest: { started.fulfill() })
        defer { server.stop() }
        let transport = URLSessionTransport(timeout: 3)
        let cancelled = expectation(description: "request cancelled")
        transport.send(URLRequest(url: server.url)) { result in
            if case .failure = result {} else { XCTFail("withdrawal must cancel the active body") }
            cancelled.fulfill()
        }
        wait(for: [started], timeout: 3)
        transport.pause()
        wait(for: [cancelled], timeout: 1)
        let blocked = expectation(description: "paused request blocked")
        transport.send(URLRequest(url: server.url)) { result in
            if case .failure = result {} else { XCTFail("paused request must not be sent") }
            blocked.fulfill()
        }
        wait(for: [blocked], timeout: 1)
        XCTAssertEqual(server.requests.count, 1)
        transport.resume()
        let small = try LocalHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        defer { small.stop() }
        let resumed = expectation(description: "fresh request works")
        transport.send(URLRequest(url: small.url)) { result in
            if case .response(status: 200, retryAfter: _, body: _) = result {} else { XCTFail("resume must allow a fresh request") }
            resumed.fulfill()
        }
        wait(for: [resumed], timeout: 3)
    }

    func testRedirectNeverForwardsProjectKeyToAnotherListener() throws {
        let destination = try LocalHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        defer { destination.stop() }
        let redirect = try LocalHTTPServer(response: "HTTP/1.1 302 Found\r\nLocation: \(destination.url)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { redirect.stop() }
        let done = expectation(description: "response")
        let transport = URLSessionTransport(timeout: 3)
        var request = URLRequest(url: redirect.url)
        request.setValue("fake-project-key", forHTTPHeaderField: "X-Corlex-Key")
        transport.send(request) { result in
            if case let .response(status, _, _) = result { XCTAssertEqual(status, 302) }
            else { XCTFail("the original local response must be observable") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(redirect.requests.count, 1)
        XCTAssertEqual(destination.requests.count, 0, "redirect destination must receive neither key nor payload")
    }

    func testOversizedResponseIsRejectedBeforeCompletion() throws {
        let body = String(repeating: "x", count: 1024 * 1024 + 1)
        let server = try LocalHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        defer { server.stop() }
        let done = expectation(description: "bounded response")
        let transport = URLSessionTransport(timeout: 3)
        transport.send(URLRequest(url: server.url)) { result in
            if case .failure = result {} else { XCTFail("oversized response must fail closed") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(server.requests.count, 1)
    }
    func testUnknownContentLengthIsCappedWhileSmallResponseStillWorks() throws {
        let body = String(repeating: "x", count: 1024 * 1024 + 1)
        let server = try LocalHTTPServer(response: "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n\(body)")
        defer { server.stop() }
        let done = expectation(description: "streamed response")
        let transport = URLSessionTransport(timeout: 3)
        transport.send(URLRequest(url: server.url)) { result in
            if case .failure = result {} else { XCTFail("unknown length still needs a streaming bound") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let small = try LocalHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        defer { small.stop() }
        let received = expectation(description: "small valid response")
        transport.send(URLRequest(url: small.url)) { result in
            if case let .response(status, _, data) = result {
                XCTAssertEqual(status, 200); XCTAssertEqual(data, Data("{}".utf8))
            } else { XCTFail("ordinary response must still work") }
            received.fulfill()
        }
        wait(for: [received], timeout: 5)
    }

    func testOneOversizedRequestDoesNotCancelAnotherPooledRequest() throws {
        let body = String(repeating: "x", count: 1024 * 1024 + 1)
        let large = try LocalHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        let small = try LocalHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        defer { large.stop(); small.stop() }
        let transport = URLSessionTransport(timeout: 3)
        let rejected = expectation(description: "large request")
        let received = expectation(description: "small request")
        transport.send(URLRequest(url: large.url)) { result in
            if case .failure = result {} else { XCTFail("large response must fail") }
            rejected.fulfill()
        }
        transport.send(URLRequest(url: small.url)) { result in
            if case let .response(status, _, data) = result {
                XCTAssertEqual(status, 200); XCTAssertEqual(data, Data("{}".utf8))
            } else { XCTFail("other request must remain independent") }
            received.fulfill()
        }
        wait(for: [rejected, received], timeout: 5)
    }

}

private final class LocalHTTPServer {
    private let listener: NWListener
    private let lock = NSLock()
    private var recorded: [String] = []
    private var connections: [NWConnection] = []
    private let closeAfterResponse: Bool
    private let onRequest: (() -> Void)?
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/test")! }

    init(response: String, closeAfterResponse: Bool = true, onRequest: (() -> Void)? = nil) throws {
        self.closeAfterResponse = closeAfterResponse
        self.onRequest = onRequest
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            self?.lock.lock(); self?.connections.append(connection); self?.lock.unlock()
            connection.start(queue: .global())
            self?.receive(connection, bytes: Data(), response: Data(response.utf8))
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 3) == .success else {
            throw NSError(domain: "CorlexTest", code: 1)
        }
    }
    func stop() {
        listener.cancel()
        lock.lock(); let active = connections; connections = []; lock.unlock()
        active.forEach { $0.cancel() }
    }

    private func receive(_ connection: NWConnection, bytes: Data, response: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            var all = bytes
            if let data { all.append(data) }
            let request = String(decoding: all, as: UTF8.self)
            if request.contains("\r\n\r\n") {
                self?.lock.lock(); self?.recorded.append(request); self?.lock.unlock()
                self?.onRequest?()
                let close = self?.closeAfterResponse ?? true
                connection.send(content: response, completion: .contentProcessed { _ in if close { connection.cancel() } })
            } else if error == nil { self?.receive(connection, bytes: all, response: response) }
            else { connection.cancel() }
        }
    }
}

final class RedirectQueueSecurityTests: XCTestCase {
    func testBlockedRedirectRetainsQueuedEventsForRetry() {
        let queue = EventQueue(storage: nil, persisted: false)
        queue.push(WireEvent(eventId: "event-1", name: "opened", timestamp: "2026-11-12T10:00:00Z", userId: nil, anonymousId: "anonymous", properties: [:], context: WireContext()))
        let dispatch = DispatchQueue(label: "redirect-queue-test")
        var config = Sender.Config(endpoint: URL(string: "https://ingest.test")!, key: "fake-key")
        config.backoff = Backoff(base: 60, maximum: 60, random: { 0 })
        let sender = Sender(queue: queue, transport: RedirectTransport(), config: config, dispatch: dispatch, log: { _ in })
        let done = expectation(description: "redirect rejected")
        dispatch.async { sender.flush { done.fulfill() } }
        wait(for: [done], timeout: 3)
        dispatch.sync { XCTAssertEqual(queue.count, 1); sender.stop() }
    }
}
private final class RedirectTransport: Transport {
    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) {
        completion(.response(status: 307, retryAfter: nil, body: Data()))
    }
}

#endif
