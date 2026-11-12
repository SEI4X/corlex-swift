import XCTest
@testable import Corlex

final class ImmediateDenialTests: XCTestCase {
    final class PausingTransport: Transport {
        private let lock = NSLock()
        private var resumes = 0
        var onPause: (() -> Void)?
        var resumeCount: Int { lock.lock(); defer { lock.unlock() }; return resumes }
        func resume() { lock.lock(); resumes += 1; lock.unlock() }
        func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) { completion(.failure) }
        func pause() {
            lock.lock(); let action = onPause; onPause = nil; lock.unlock()
            action?()
        }
    }

    private func client(_ transport: Transport, folder: URL) throws -> CorlexClient {
        var options = Harness.fastOptions()
        options.config.enabled = false
        options.flushInterval = 60
        let env = ClientEnvironment(storage: Storage(directory: folder), transport: transport, device: testDevice,
            trackingStatus: { .granted }, now: Date.init, installGlobalHooks: false, backoff: Backoff())
        let client = try XCTUnwrap(CorlexClient(key: testSDKKey, options: options, env: env))
        client.queue.sync { client.runtime?.sender.stop() }
        return client
    }

    func testGlobalRefusalIsVisibleBeforeTransportPauseCanWaitOnAnotherCallback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-refusal-\(UUID().uuidString)")
        let transport = PausingTransport()
        let client = try client(transport, folder: folder)
        let ledger = try XCTUnwrap(client.storage?.scope?.ledger)
        let paused = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
        defer { client.stop(); client.queue.sync {}; try? FileManager.default.removeItem(at: folder) }
        transport.onPause = { paused.signal(); _ = release.wait(timeout: .now() + 5) }
        DispatchQueue.global().async { client.optOut(); returned.signal() }
        XCTAssertEqual(paused.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(ledger.memoryFence()?.state, .denied)
        release.signal()
        XCTAssertEqual(returned.wait(timeout: .now() + 3), .success)
        client.queue.sync {}
    }

    func testPublicOptOutReturnsBeforeHeldFilesystemLockAndKeepsRefusalVisible() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-refusal-io-\(UUID().uuidString)")
        let client = try client(StubTransport(), folder: folder)
        let scope = try XCTUnwrap(client.storage?.scope)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
        let holderDone = DispatchSemaphore(value: 0)
        defer { client.stop(); client.queue.sync {}; try? FileManager.default.removeItem(at: folder) }
        DispatchQueue.global().async {
            _ = scope.ledger.authorized(record: scope.record) { entered.signal(); _ = release.wait(timeout: .now() + 5) }
            holderDone.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async { client.optOut(); returned.signal() }
        let immediate = returned.wait(timeout: .now() + 1)
        XCTAssertEqual(immediate, .success)
        XCTAssertEqual(scope.ledger.memoryFence()?.state, .denied)
        release.signal()
        if immediate != .success { XCTAssertEqual(returned.wait(timeout: .now() + 3), .success) }
        XCTAssertEqual(holderDone.wait(timeout: .now() + 3), .success)
        client.queue.sync {}
    }

    func testAlreadyQueuedOptInCannotUndoTheNewerImmediateWithdrawal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-queued-grant-\(UUID().uuidString)")
        let transport = PausingTransport()
        let client = try client(transport, folder: folder)
        let ledger = try XCTUnwrap(client.storage?.scope?.ledger)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { client.stop(); client.queue.sync {}; try? FileManager.default.removeItem(at: folder) }
        client.queue.async { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        client.optIn()
        client.optOut()
        release.signal()
        client.queue.sync {}
        XCTAssertEqual(transport.resumeCount, 0)
        XCTAssertEqual(ledger.current()?.state, .denied)
        XCTAssertEqual(client.currentConsent(), .denied)
    }
}
