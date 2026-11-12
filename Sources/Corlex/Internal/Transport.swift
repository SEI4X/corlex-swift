import Foundation

/// What came back from a request. A `failure` is the network (offline, timeout, TLS), not the server.
enum TransportResult {
    case response(status: Int, retryAfter: String?, body: Data)
    case failure
}

/// The one place the SDK touches the network, so tests can put a stub in its place.
protocol Transport: AnyObject {
    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void)
    func pause()
    func resume()
}
extension Transport {
    func pause() {}
    func resume() {}
}

/// Ephemeral pooled session: no redirects, cookies, credentials, cache, or unbounded responses.
final class URLSessionTransport: Transport {
    private let receiver: BoundedResponses
    private let session: URLSession

    init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let receiver = BoundedResponses()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.receiver = receiver
        session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
    }

    deinit { session.invalidateAndCancel() }

    func pause() { receiver.pause() }
    func resume() { receiver.resume() }

    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) {
        let task = session.dataTask(with: request)
        if receiver.register(task, completion: completion) { task.resume() }
        else { task.cancel(); completion(.failure) }
    }
}

/// No reference back to the transport/session: pooled connections do not create a retain cycle.
/// State registration and delegate callbacks are protected by the lock.
private final class BoundedResponses: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class State {
        let task: URLSessionTask
        let epoch: UInt64
        let completion: (TransportResult) -> Void
        var response: HTTPURLResponse?
        var body = Data()
        var rejected = false
        init(_ task: URLSessionTask, epoch: UInt64, completion: @escaping (TransportResult) -> Void) {
            self.task = task; self.epoch = epoch; self.completion = completion
        }
    }
    private static let maxBytes = 1024 * 1024
    private let lock = NSLock()
    private var pending: [Int: State] = [:]
    private var paused = false
    private var epoch: UInt64 = 0

    func register(_ task: URLSessionTask, completion: @escaping (TransportResult) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !paused else { return false }
        pending[task.taskIdentifier] = State(task, epoch: epoch, completion: completion)
        return true
    }

    func pause() {
        lock.lock()
        paused = true
        epoch &+= 1
        let tasks = pending.values.map { $0.task }
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    func resume() {
        lock.lock(); paused = false; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Custom project-key headers and event bodies must never reach a redirect destination.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let state = pending[dataTask.taskIdentifier]
        let allowed = state != nil && response is HTTPURLResponse && response.expectedContentLength <= Self.maxBytes
        state?.response = response as? HTTPURLResponse
        state?.rejected = !allowed
        lock.unlock()
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let state = pending[dataTask.taskIdentifier] else { lock.unlock(); return }
        let rejected = state.rejected || data.count > Self.maxBytes - state.body.count
        if rejected {
            state.rejected = true
            state.body.removeAll(keepingCapacity: false)
        } else { state.body.append(data) }
        lock.unlock()
        if rejected { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = pending.removeValue(forKey: task.taskIdentifier)
        let current = !paused && state?.epoch == epoch
        lock.unlock()
        guard let state else { return }
        if current, !state.rejected, error == nil, let response = state.response {
            state.completion(.response(status: response.statusCode,
                                       retryAfter: response.value(forHTTPHeaderField: "Retry-After"), body: state.body))
        } else { state.completion(.failure) }
    }
}

/// Exponential backoff with equal jitter: half fixed, half random (as `sdk-core` does).
struct Backoff {
    var base: TimeInterval = 1
    var maximum: TimeInterval = 60
    /// 0..<1; injected so tests are deterministic.
    var random: () -> Double = { Double.random(in: 0..<1) }

    func delay(attempt: Int) -> TimeInterval {
        let exponent = Double(max(0, min(attempt - 1, 20)))
        let ceiling = min(base * pow(2, exponent), maximum)
        return ceiling / 2 + random() * ceiling / 2
    }

    /// `Retry-After` in seconds (the only form servers here send), capped at five minutes.
    static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let header, let seconds = Double(header.trimmingCharacters(in: .whitespaces)),
              seconds >= 0 else { return nil }
        return min(seconds, 300)
    }
}
