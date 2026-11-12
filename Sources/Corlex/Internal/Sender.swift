import Foundation

/// Delivers the queue to `POST /v1/batch` (services/ingest/docs/protocol.md): the key goes in
/// the `X-Corlex-Key` header, never in a URL. `202` and any 4xx except 429 drop the batch, 429
/// waits for `Retry-After`, blocked redirects, 5xx and network errors retry with backoff and the same `event_id`s,
/// 401/403 stop sending (the key is wrong or the project is blocked), 413 halves the batch.
/// Everything runs on the client's serial queue.
final class Sender {
    struct Config {
        var endpoint: URL
        var key: String
        var batchSize = 20
        var flushInterval: TimeInterval = 5
        var backoff = Backoff()
        var allowed: () -> Bool = { true }
    }

    private enum Outcome: Equatable {
        case ok
        case drop(status: Int)
        case split
        case halt(status: Int)
        case retry(after: TimeInterval?)
    }

    private let queue: EventQueue
    private let transport: Transport
    private let config: Config
    private let dispatch: DispatchQueue
    private let log: (String) -> Void

    private var timer: DispatchWorkItem?
    private var inflight = false
    private var waiters: [() -> Void] = []
    private var attempts = 0
    private var backingOff = false
    private var limit: Int
    private var paused = false
    private var rejected = false
    private var epoch: UInt64 = 0

    init(queue: EventQueue, transport: Transport, config: Config, dispatch: DispatchQueue, log: @escaping (String) -> Void) {
        self.queue = queue
        self.transport = transport
        self.config = config
        self.dispatch = dispatch
        self.log = log
        self.limit = max(1, min(config.batchSize, Limits.maxBatchEvents))
    }

    private var stopped: Bool { paused || rejected || !config.allowed() }

    /// Called after an event was queued: send now when a batch is full, else after the interval.
    func schedule() {
        if stopped || queue.count == 0 || backingOff { return }
        if queue.count >= config.batchSize {
            flush()
        } else if timer == nil {
            arm(after: config.flushInterval)
        }
    }

    /// Sends everything queued. `completion` runs when the queue is empty or delivery failed
    /// (a retry is then scheduled).
    func flush(completion: (() -> Void)? = nil) {
        if let completion { waiters.append(completion) }
        if inflight { return }
        inflight = true
        disarm()
        backingOff = false
        step()
    }

    /// Opt-out or no consent: stop sending until `resume()`.
    func stop() {
        paused = true
        epoch &+= 1
        backingOff = false
        transport.pause()
        disarm()
    }

    func resume() {
        transport.resume()
        paused = false
        schedule()
    }

    // MARK: - Delivery loop

    private func step() {
        guard !stopped, queue.count > 0 else { return finish() }
        let batch = queue.peek(count: limit)
        let epoch = self.epoch
        post(batch) { [weak self] outcome in
            guard let self else { return }
            self.dispatch.async {
                guard !self.stopped, epoch == self.epoch else {
                    if self.stopped { self.finish() } else { self.step() }
                    return
                }
                if self.apply(outcome, to: batch) { self.step() } else { self.finish() }
            }
        }
    }

    private func finish() {
        inflight = false
        let done = waiters
        waiters = []
        done.forEach { $0() }
    }

    /// Returns whether the loop may continue.
    private func apply(_ outcome: Outcome, to batch: [EventQueue.Item]) -> Bool {
        switch outcome {
        case .ok:
            attempts = 0
            limit = min(limit * 2, max(1, min(config.batchSize, Limits.maxBatchEvents)))
            queue.drop(batch)
            return true
        case .drop(let status):
            log("dropping \(batch.count) event(s): the server answered \(status)")
            queue.drop(batch)
            return true
        case .split:
            limit = max(1, batch.count / 2)
            return true
        case .halt(let status):
            print("[corlex] the key was rejected (\(status)); events are not sent")
            rejected = true
            queue.clear()
            return false
        case .retry(let after):
            retryLater(after: after)
            return false
        }
    }

    private func retryLater(after: TimeInterval?) {
        attempts += 1
        let delay = max(config.backoff.delay(attempt: attempts), after ?? 0)
        log("delivery failed, retry in \(Int(delay * 1000)) ms (attempt \(attempts))")
        backingOff = true
        arm(after: delay)
    }

    private func post(_ batch: [EventQueue.Item], completion: @escaping (Outcome) -> Void) {
        var request = URLRequest(url: config.endpoint.appendingPathComponent("v1/batch"))
        request.httpMethod = "POST"
        request.httpBody = EventQueue.body(for: batch)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.key, forHTTPHeaderField: "X-Corlex-Key")
        let count = batch.count
        transport.send(request) { result in
            completion(Self.classify(result, count: count))
        }
    }

    private static func classify(_ result: TransportResult, count: Int) -> Outcome {
        guard case .response(let status, let retryAfter, _) = result else { return .retry(after: nil) }
        switch status {
        case 200..<300: return .ok
        case 401, 403: return .halt(status: status)
        case 413: return count > 1 ? .split : .drop(status: status)
        case 300..<400, 429, 500...: return .retry(after: Backoff.retryAfter(retryAfter))
        default: return .drop(status: status)
        }
    }

    // MARK: - Timer

    private func arm(after delay: TimeInterval) {
        disarm()
        let epoch = self.epoch
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.epoch == epoch else { return }
            self.timer = nil
            self.backingOff = false
            self.flush()
        }
        timer = item
        dispatch.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func disarm() {
        timer?.cancel()
        timer = nil
    }
}
