import XCTest
@testable import Corlex

final class QueueAndSanitizerTests: XCTestCase {
    private var folder: URL!
    private var storage: Storage!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-q-\(UUID().uuidString)")
        storage = Storage(directory: folder)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func event(_ id: String, name: String = "tap", padding: Int = 0) -> WireEvent {
        WireEvent(
            eventId: id, name: name, timestamp: "2026-10-20T11:59:00.250Z", userId: nil, anonymousId: "a_1",
            properties: padding > 0 ? ["pad": .string(String(repeating: "x", count: padding))] : [:],
            context: WireContext()
        )
    }

    // MARK: - Queue

    func testQueueSurvivesARestart() {
        let queue = EventQueue(storage: storage, persisted: true)
        queue.push(event("e1"))
        queue.push(event("e2", name: "purchase"))
        let reloaded = EventQueue(storage: storage, persisted: true)
        XCTAssertEqual(reloaded.items.map(\.id), ["e1", "e2"])
        XCTAssertTrue(reloaded.contains("e2"))
    }

    func testDroppingRemovesExactlyThatBatchFromDisk() {
        let queue = EventQueue(storage: storage, persisted: true)
        ["e1", "e2", "e3"].forEach { queue.push(event($0)) }
        queue.drop(queue.peek(count: 2))
        XCTAssertEqual(EventQueue(storage: storage, persisted: true).items.map(\.id), ["e3"])
        queue.drop(queue.peek(count: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.url(EventQueue.fileName).path))
    }

    func testAHalfWrittenLineAfterACrashIsSkipped() {
        storage.write(Data("{\"event_id\":\"e1\",\"name\":\"a\"}\n{\"event_id\":\"e2\",\"na".utf8), to: EventQueue.fileName)
        XCTAssertEqual(EventQueue(storage: storage, persisted: true).items.map(\.id), ["e1"])
    }

    func testOldestEventsGoFirstOverTheCap() {
        let queue = EventQueue(storage: storage, persisted: true)
        for index in 0..<(Limits.maxQueueEvents + 5) { queue.push(event("e\(index)")) }
        XCTAssertEqual(queue.count, Limits.maxQueueEvents)
        XCTAssertEqual(queue.items.first?.id, "e5")
        XCTAssertEqual(EventQueue(storage: storage, persisted: true).count, Limits.maxQueueEvents)
    }

    func testByteCapTrimsTheOldest() {
        let queue = EventQueue(storage: storage, persisted: false)
        let big = Limits.maxEventBytes - 600
        for index in 0..<200 { queue.push(event("e\(index)", padding: big)) }
        XCTAssertLessThan(queue.count, 200)
        XCTAssertLessThanOrEqual(queue.items.reduce(0) { $0 + $1.line.count + 1 }, Limits.maxQueueBytes)
        XCTAssertEqual(queue.items.last?.id, "e199")
    }

    func testAnEventOverTheProtocolLimitIsRefused() {
        let queue = EventQueue(storage: storage, persisted: true)
        XCTAssertFalse(queue.push(event("big", padding: Limits.maxEventBytes)))
        XCTAssertEqual(queue.count, 0)
    }

    func testNothingTouchesTheDiskWhileNotPersisted() {
        let queue = EventQueue(storage: storage, persisted: false)
        queue.push(event("e1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        queue.enablePersistence()
        XCTAssertEqual(EventQueue(storage: storage, persisted: true).items.map(\.id), ["e1"])
    }

    func testBatchBodyIsTheEventsArrayAndRespectsTheByteBudget() throws {
        let queue = EventQueue(storage: nil, persisted: false)
        ["e1", "e2", "e3"].forEach { queue.push(event($0, padding: 400)) }
        let one = queue.items[0].line.count + 1
        let batch = queue.peek(count: 10, maxBytes: one * 2 + 10)
        XCTAssertEqual(batch.count, 2)
        let json = try JSONSerialization.jsonObject(with: EventQueue.body(for: batch)) as? [String: Any]
        XCTAssertEqual((json?["events"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(queue.peek(count: 10, maxBytes: 1).count, 1, "one event always goes")
    }

    // MARK: - Sanitizer

    func testLongStringsAreCutOnACharacterBoundary() {
        let value = String(repeating: "я", count: 2000)
        let cleaned = PropertySanitizer.sanitize(["s": value])
        guard case .string(let text) = cleaned["s"] else { return XCTFail("no string") }
        XCTAssertEqual(text.utf8.count, Limits.maxPropertyString)
        XCTAssertTrue(value.hasPrefix(text))
    }

    func testTypesAreKeptAndUnsupportedOnesDropped() {
        let cleaned = PropertySanitizer.sanitize([
            "flag": true, "n": 7, "f": 1.5, "nan": Double.nan, "s": "x", "date": Date(timeIntervalSince1970: 0),
            "list": [1, "a"], "nested": ["k": 1], "closure": { 1 }, "url": URL(string: "https://x.test/?token=1")!,
        ])
        XCTAssertEqual(cleaned["flag"], .bool(true))
        XCTAssertEqual(cleaned["n"], .int(7))
        XCTAssertEqual(cleaned["f"], .double(1.5))
        XCTAssertEqual(cleaned["nan"], .null)
        XCTAssertEqual(cleaned["date"], .string("1970-01-01T00:00:00.000Z"))
        XCTAssertEqual(cleaned["list"], .array([.int(1), .string("a")]))
        XCTAssertEqual(cleaned["nested"], .object(["k": .int(1)]))
        XCTAssertNil(cleaned["closure"])
        XCTAssertNil(cleaned["url"], "URLs carry query strings, which are never captured")
    }

    func testDepthKeysAndArraysFollowTheProtocolLimits() {
        let deep: [String: Any] = ["a": ["b": ["c": ["d": ["e": 1]]]]]
        let cleaned = PropertySanitizer.sanitize(deep)
        XCTAssertEqual(cleaned["a"], .object(["b": .object(["c": .object([:])])]), "nesting stops after level 4")
        let many = Dictionary(uniqueKeysWithValues: (0..<150).map { ("k\($0)", $0) })
        XCTAssertEqual(PropertySanitizer.sanitize(many).count, Limits.maxProperties)
        XCTAssertEqual(PropertySanitizer.sanitize(["l": Array(0..<300)])["l"], .array((0..<100).map { .int(Int64($0)) }))
        XCTAssertNil(PropertySanitizer.sanitize(["": 1])[""])
    }

    func testEventNameRule() {
        XCTAssertTrue(EventName.isValid("screen_view"))
        XCTAssertTrue(EventName.isValid("corlex.exposure"))
        XCTAssertFalse(EventName.isValid("Purchase"))
        XCTAssertFalse(EventName.isValid(""))
        XCTAssertFalse(EventName.isValid(String(repeating: "a", count: 129)))
        XCTAssertFalse(EventName.isValid("with space"))
    }
}
