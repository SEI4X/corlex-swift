import Foundation

/// A late response cannot be accepted by a different activation, including memory-only regrant.
final class BoundTransport: Transport {
    private let base: Transport
    private let binding: ClientBinding
    init(base: Transport, binding: ClientBinding) { self.base = base; self.binding = binding }
    func pause() { base.pause() }
    func resume() { if binding.canSend { base.resume() } }
    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) {
        let token = binding.token
        guard binding.canSend else { return completion(.failure) }
        base.send(request) { [binding] result in
            completion(binding.token == token && binding.canSend ? result : .failure)
        }
    }
}
