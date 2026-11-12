import XCTest
@testable import Corlex

/// A transport that records requests and answers from a script.
final class StubTransport: Transport {
    typealias Responder = (URLRequest) -> TransportResult

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var responder: Responder = { _ in .response(status: 202, retryAfter: nil, body: Data()) }

    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) {
        lock.lock()
        recorded.append(request)
        let responder = self.responder
        lock.unlock()
        completion(responder(request))
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Requests to `POST /v1/batch`.
    var batches: [URLRequest] { requests.filter { $0.url?.path == "/v1/batch" } }

    /// The events of every batch request, in order.
    var sentEvents: [[String: Any]] {
        batches.flatMap { request -> [[String: Any]] in
            guard let body = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return [] }
            return json["events"] as? [[String: Any]] ?? []
        }
    }

    func sentNames() -> [String] { sentEvents.compactMap { $0["name"] as? String } }

    static func ok(_ status: Int = 202, retryAfter: String? = nil, body: String = "") -> TransportResult {
        .response(status: status, retryAfter: retryAfter, body: Data(body.utf8))
    }
}

let testSDKKey = "ck_test_" + String(repeating: "x", count: 43)

let testDevice = DeviceInfo(
    appVersion: "1.4.2", build: "87", osVersion: "18.3", deviceModel: "iPhone16,2", locale: "en-US"
)

/// A client over a temporary folder and a stub network.
struct Harness {
    let folder: URL
    var storage: Storage { client.storage ?? Storage(directory: folder.appendingPathComponent("inactive")) }
    let transport = StubTransport()
    let client: CorlexClient

    init(
        options: CorlexOptions = Harness.fastOptions(),
        storedFiles: [String: String] = [:],
        crashFiles: [String: String] = [:],
        att: CorlexConsent = .pending,
        folder: URL? = nil,
        prepare: ((StubTransport) -> Void)? = nil
    ) {
        let folder = folder ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("corlex-tests-\(UUID().uuidString)", isDirectory: true)
        self.folder = folder
        let legacy = Storage(directory: folder)
        let owner = StorageBinding.digest(key: testSDKKey, endpoint: options.endpoint, configEndpoint: options.configEndpoint)!
        let ledger = PrivacyLedger(root: folder.appendingPathComponent("sdk-ios"))
        let requested: PrivacyRecord.State = storedFiles["consent"].flatMap(PrivacyRecord.State.init(rawValue:)) ??
            (options.consent == .pending ? .pending : .granted)
        let ceiling: PrivacyRecord.State = options.consent == .att ? PrivacyRecord.State(rawValue: att.rawValue)! : .granted
        if let record = ledger.prepare(requested: requested, ceiling: ceiling), let path = ledger.scope(owner: owner, record: record) {
            let fixture = Storage(directory: path)
            for (name, text) in storedFiles { fixture.writeText(text, to: name) }
            for (name, text) in crashFiles {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                if var header = try? JSONSerialization.jsonObject(with: Data((lines.first ?? "").utf8)) as? [String: Any],
                   let directory = fixture.prepare(subfolder: "crashes") {
                    header["owner"] = owner; header["generation"] = record.generation
                    let raw = (try? JSONSerialization.data(withJSONObject: header)) ?? Data()
                    let frames = lines.dropFirst().joined(separator: "\n")
                    try? (raw + Data(("\n" + frames).utf8)).write(to: directory.appendingPathComponent(name))
                }
            }
        }
        prepare?(transport)
        var env = ClientEnvironment(
            storage: legacy, transport: transport, device: testDevice,
            trackingStatus: { att }, now: Date.init, installGlobalHooks: false,
            backoff: Backoff(base: 0.01, maximum: 0.05, random: { 0.5 })
        )
        env.installGlobalHooks = false
        client = CorlexClient(key: testSDKKey, options: options, env: env)!
    }

    static func fastOptions() -> CorlexOptions {
        var options = CorlexOptions()
        options.endpoint = URL(string: "https://ingest.test")!
        options.configEndpoint = URL(string: "https://config.test")!
        options.flushInterval = 0.05
        options.autocapture = .none
        return options
    }

    /// Waits for everything queued on the client so far.
    func settle() { client.queue.sync {} }

    func cleanUp() { client.stop(); settle(); try? FileManager.default.removeItem(at: folder) }

    var diskFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: storage.directory.path)) ?? []
    }
}

extension XCTestCase {
    /// Spins the run loop until `condition` holds or the time is up.
    func wait(timeout: TimeInterval = 3, for condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "condition not met in \(timeout)s", file: file, line: line)
    }
}
