import Foundation

/// Events waiting for delivery: in memory, mirrored to `queue.jsonl` (one event per line) so a
/// crash, a kill or a restart does not lose them. An event leaves the queue only after the
/// server acknowledged it or refused it for good. Not thread-safe: the client's queue owns it.
final class EventQueue {
    struct Item {
        let id: String
        /// The event as JSON, one line, no newline.
        let line: Data
    }

    static let fileName = "queue.jsonl"

    private(set) var items: [Item] = []
    private var bytes = 0
    private var persisted: Bool
    private let storage: Storage?
    private let encoder = JSONEncoder()

    /// `persisted` false keeps events in memory only (consent pending).
    init(storage: Storage?, persisted: Bool) {
        self.storage = storage
        self.persisted = persisted
        if persisted { load() }
    }

    var count: Int { items.count }

    func contains(_ eventId: String) -> Bool {
        items.contains { $0.id == eventId }
    }

    /// Adds an event; returns false when it is too big for the protocol or cannot be encoded.
    @discardableResult
    func push(_ event: WireEvent) -> Bool {
        guard let line = try? encoder.encode(event), line.count <= Limits.maxEventBytes else { return false }
        items.append(Item(id: event.eventId, line: line))
        bytes += line.count + 1
        if trim() { rewrite() } else { append(line) }
        return true
    }

    /// The oldest events, at most `count` and at most `maxBytes` of body (one is always returned).
    func peek(count: Int, maxBytes: Int = Limits.maxBatchBytes) -> [Item] {
        var out: [Item] = []
        var size = 0
        for item in items.prefix(count) {
            size += item.line.count + 1
            if size > maxBytes && !out.isEmpty { break }
            out.append(item)
        }
        return out
    }

    /// Removes exactly the events of a delivered or dropped batch.
    func drop(_ batch: [Item]) {
        let ids = Set(batch.map(\.id))
        items.removeAll { ids.contains($0.id) }
        bytes = items.reduce(0) { $0 + $1.line.count + 1 }
        rewrite()
    }

    func clear() {
        items = []
        bytes = 0
        storage?.remove(Self.fileName)
    }

    /// Consent arrived: start mirroring the queue to storage.
    func enablePersistence() {
        persisted = true
        rewrite()
    }

    /// The request body for a batch: `{"events":[…]}` without decoding the events again.
    static func body(for batch: [Item]) -> Data {
        var body = Data("{\"events\":[".utf8)
        for (index, item) in batch.enumerated() {
            if index > 0 { body.append(0x2c) }
            body.append(item.line)
        }
        body.append(contentsOf: "]}".utf8)
        return body
    }

    // MARK: - Disk

    private struct IDOnly: Decodable {
        let eventId: String
        enum CodingKeys: String, CodingKey { case eventId = "event_id" }
    }

    private func load() {
        guard let data = storage?.read(Self.fileName) else { return }
        let decoder = JSONDecoder()
        for slice in data.split(separator: 0x0a) where !slice.isEmpty {
            let line = Data(slice)
            // A line cut by a crash in the middle of a write is skipped, not fatal.
            guard let head = try? decoder.decode(IDOnly.self, from: line) else { continue }
            items.append(Item(id: head.eventId, line: line))
            bytes += line.count + 1
        }
        if trim() { rewrite() }
    }

    /// Oldest events go first when over the caps. Returns whether anything was removed.
    private func trim() -> Bool {
        var removed = 0
        while items.count - removed > Limits.maxQueueEvents
            || (bytes > Limits.maxQueueBytes && items.count - removed > 1) {
            bytes -= items[removed].line.count + 1
            removed += 1
        }
        if removed > 0 { items.removeFirst(removed) }
        return removed > 0
    }

    private func append(_ line: Data) {
        guard persisted else { return }
        storage?.append(line + Data([0x0a]), to: Self.fileName)
    }

    private func rewrite() {
        guard persisted, let storage else { return }
        if items.isEmpty {
            storage.remove(Self.fileName)
            return
        }
        var data = Data()
        for item in items {
            data.append(item.line)
            data.append(0x0a)
        }
        storage.write(data, to: Self.fileName)
    }
}
