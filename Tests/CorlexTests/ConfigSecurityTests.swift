import Foundation
import XCTest
@testable import Corlex

final class ConfigSecurityTests: XCTestCase {
    private func document(_ param: String, experiments: String = "") -> Data {
        Data("{\"version\":1,\"etag\":\"safe\",\"params\":[\(param)]\(experiments)}".utf8)
    }
    private let valid = #"{"k":"enabled","t":"bool","v":true,"r":10000}"#

    func testMalformedCompiledValuesAreRejected() {
        let malformed = [
            #"{"k":"enabled","t":"bool","v":true,"r":10001}"#,
            #"{"k":"enabled","t":"bool","v":true,"r":-1}"#,
            #"{"k":"__proto__","t":"bool","v":true,"r":10000}"#,
            #"{"k":"enabled","t":"unknown","v":true,"r":10000}"#,
            #"{"k":"enabled","v":true,"r":10000}"#,
            #"{"k":"enabled","t":"bool","v":"true","r":10000}"#,
            #"{"k":"enabled","t":"bool","v":true,"r":10000,"o":{"server":true}}"#,
            #"{"k":"enabled","t":"bool","v":true,"r":10000,"o":{"ios":"true"}}"#,
            #"{"k":"enabled","t":"bool","v":true,"r":10000,"o":null}"#,
            valid + "," + valid,
        ]
        for param in malformed { XCTAssertNil(ConfigValidation.decode(document(param)), param) }
        XCTAssertNotNil(ConfigValidation.decode(document(valid)))
    }

    func testExperimentBoundsDuplicatesAndNullableOptionalsAreRejected() {
        let bad = [
            #"{"k":"test","s":"salt","v":[{"n":"a","b":0,"v":true},{"n":"b","b":10000,"v":false}]}"#,
            #"{"k":"test","s":"salt","v":[{"n":"a","b":7000,"v":true},{"n":"b","b":6000,"v":false},{"n":"c","b":10000,"v":true}]}"#,
            #"{"k":"test","s":"salt","v":[{"n":"a","b":5000,"v":true},{"n":"a","b":10000,"v":false}]}"#,
            #"{"k":"test","s":"salt","p":null,"v":[{"n":"a","b":5000,"v":true},{"n":"b","b":10000,"v":false}]}"#,
        ]
        for experiment in bad { XCTAssertNil(ConfigValidation.decode(document(valid, experiments: ",\"experiments\":[\(experiment)]"))) }
        XCTAssertNil(ConfigValidation.decode(document(valid, experiments: ",\"experiments\":null")))
        let experiment = #"{"k":"test","s":"salt","p":"enabled","v":[{"n":"a","b":5000,"v":true},{"n":"b","b":10000,"v":false}]}"#
        XCTAssertNotNil(ConfigValidation.decode(document(valid, experiments: ",\"experiments\":[\(experiment)]")))
        XCTAssertNil(ConfigValidation.decode(document(valid, experiments: ",\"experiments\":[\(experiment),\(experiment)]")))
    }

    func testResourceAndHeaderBoundsApplyBeforeDecoding() {
        let nested = String(repeating: "[", count: 14) + "0" + String(repeating: "]", count: 14)
        XCTAssertNil(ConfigValidation.decode(document("{\"k\":\"x\",\"t\":\"json\",\"v\":\(nested),\"r\":10000}")))
        let huge = String(repeating: "x", count: 1024 * 1024)
        XCTAssertNil(ConfigValidation.decode(document("{\"k\":\"x\",\"t\":\"string\",\"v\":\"\(huge)\",\"r\":10000}")))
        let injected = try! JSONSerialization.data(withJSONObject: ["version": 1, "etag": "bad\r\nheader", "params": []] as [String: Any])
        XCTAssertNil(ConfigValidation.decode(injected))
        XCTAssertNil(ConfigValidation.decode(Data("{\"version\":1,\"etag\":\"\(String(repeating: "x", count: 257))\",\"params\":[]}".utf8)))
        let params = (0...1000).map { "{\"k\":\"p\($0)\",\"t\":\"bool\",\"v\":true,\"r\":10000}" }.joined(separator: ",")
        XCTAssertNil(ConfigValidation.decode(document(params)))
    }

    func testObjectKeyBudgetAndIdentifierLengths() {
        let object = (0...65536).map { "\"k\($0)\":0" }.joined(separator: ",")
        XCTAssertNil(ConfigValidation.decode(document("{\"k\":\"x\",\"t\":\"json\",\"v\":{\(object)},\"r\":10000}")))
        let key = String(repeating: "x", count: 129)
        XCTAssertNil(ConfigValidation.decode(document("{\"k\":\"\(key)\",\"t\":\"bool\",\"v\":true,\"r\":10000}")))
        let badSalt = "{\"k\":\"test\",\"s\":\"\(key)\",\"v\":[{\"n\":\"a\",\"b\":5000,\"v\":true},{\"n\":\"b\",\"b\":10000,\"v\":false}]}"
        XCTAssertNil(ConfigValidation.decode(document(valid, experiments: ",\"experiments\":[\(badSalt)]")))
    }

    func testCacheMustPassTheSameValidationAndSizeBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-cache-\(UUID().uuidString)")
        let storage = Storage(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let badDoc = document(#"{"k":"enabled","t":"bool","v":true,"r":10001}"#)
        let validDoc = document(valid)
        let hugeDoc = document("{\"k\":\"x\",\"t\":\"string\",\"v\":\"\(String(repeating: "x", count: ConfigValidation.maxCacheBytes))\",\"r\":10000}")
        let cases: [(Data, String)] = [(badDoc, "safe"), (validDoc, "different"), (hugeDoc, "safe")]
        for (doc, etag) in cases {
            let object = try JSONSerialization.jsonObject(with: doc)
            let data = try JSONSerialization.data(withJSONObject: ["etag": etag, "doc": object])
            storage.write(data, to: RemoteConfig.fileName)
            let dispatch = DispatchQueue(label: "cache-validation-test")
            let remote = RemoteConfig(options: .init(storage: storage, endpoint: URL(string: "https://config.test")!, key: "fake-key", idOf: { "person" }, expose: { _, _ in }, log: { _ in }), transport: ConfigSecurityTransport(body: Data(), status: 404), dispatch: dispatch)
            let ready = expectation(description: "cache validation")
            dispatch.sync { remote.start(); remote.refresh { ready.fulfill() } }
            wait(for: [ready], timeout: 3)
            dispatch.sync {
                XCTAssertTrue(remote.getAll().isEmpty)
                XCTAssertNil(storage.read(RemoteConfig.fileName))
                remote.stop(wipe: true)
            }
        }
    }

    func testUnsafeETagsNeverReachAConditionalHeader() throws {
        let controls = [UInt8(0), 9, 10, 13, 31, 127].map { "bad" + String(UnicodeScalar($0)) + "value" }
        for etag in controls + ["", "é", "😀"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-etag-\(UUID().uuidString)")
            let storage = Storage(directory: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let doc: [String: Any] = ["version": 1, "etag": etag, "params": []]
            XCTAssertNil(ConfigValidation.decode(try JSONSerialization.data(withJSONObject: doc)), etag)
            storage.write(try JSONSerialization.data(withJSONObject: ["etag": etag, "doc": doc]), to: RemoteConfig.fileName)
            let dispatch = DispatchQueue(label: "cached-etag-test")
            let transport = ConfigHeaderTransport()
            let remote = RemoteConfig(options: .init(storage: storage, endpoint: URL(string: "https://config.test")!, key: "fake-key", idOf: { "person" }, expose: { _, _ in }, log: { _ in }), transport: transport, dispatch: dispatch)
            let ready = expectation(description: "safe refresh")
            dispatch.sync { remote.start(); remote.refresh { ready.fulfill() } }
            wait(for: [ready], timeout: 3)
            dispatch.sync { XCTAssertEqual(transport.calls, 1); XCTAssertNil(transport.etag); XCTAssertNil(storage.read(RemoteConfig.fileName)); remote.stop(wipe: true) }
        }
    }

    func testOldConfigCannotCompleteTheFreshConsentDownload() {
        let dispatch = DispatchQueue(label: "config-generation-test")
        let transport = DeferredConfigTransport()
        let remote = RemoteConfig(options: .init(endpoint: URL(string: "https://config.test")!, key: "fake-key", idOf: { "person" }, expose: { _, _ in }, log: { _ in }), transport: transport, dispatch: dispatch)
        dispatch.sync { remote.start() }
        dispatch.sync { XCTAssertEqual(transport.callbacks.count, 1); remote.stop(wipe: true); remote.start() }
        var freshFinished = false
        let ready = expectation(description: "fresh config")
        dispatch.sync { remote.refresh { freshFinished = true; ready.fulfill() }; XCTAssertEqual(transport.callbacks.count, 2) }
        guard transport.callbacks.count == 2 else { return }
        transport.callbacks[0](.response(status: 200, retryAfter: nil, body: document(valid)))
        dispatch.sync { XCTAssertFalse(freshFinished); XCTAssertTrue(remote.getAll().isEmpty) }
        transport.callbacks[1](.response(status: 200, retryAfter: nil, body: document(valid)))
        wait(for: [ready], timeout: 3)
        dispatch.sync { XCTAssertEqual(remote.get("enabled", fallback: .bool(false)), .bool(true)); remote.stop(wipe: true) }
    }

    func testUntrustedNetworkDocumentCannotReachReads() {
        let dispatch = DispatchQueue(label: "invalid-config-test")
        let transport = ConfigSecurityTransport(body: document(#"{"k":"enabled","t":"bool","v":true,"r":10001}"#))
        let remote = RemoteConfig(options: .init(endpoint: URL(string: "https://config.test")!, key: "fake-key", idOf: { "synthetic-person" }, expose: { _, _ in }, log: { _ in }), transport: transport, dispatch: dispatch)
        let ready = expectation(description: "download")
        dispatch.sync { remote.start(); remote.refresh { ready.fulfill() } }
        wait(for: [ready], timeout: 3)
        dispatch.sync { XCTAssertEqual(remote.get("enabled", fallback: .bool(false)), .bool(false)); remote.stop(wipe: true) }
    }
}

private final class ConfigSecurityTransport: Transport {
    let body: Data
    let status: Int
    init(body: Data, status: Int = 200) { self.body = body; self.status = status }
    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) {
        completion(.response(status: status, retryAfter: nil, body: body))
    }
}

private final class DeferredConfigTransport: Transport {
    var callbacks: [(TransportResult) -> Void] = []
    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) { callbacks.append(completion) }
}

private final class ConfigHeaderTransport: Transport {
    var etag: String?
    var calls = 0
    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) {
        calls += 1
        etag = request.value(forHTTPHeaderField: "If-None-Match")
        completion(.response(status: 304, retryAfter: nil, body: Data()))
    }
}
