import XCTest
@testable import Corlex

final class RemoteConfigTests: XCTestCase {
    private var harnesses: [Harness] = []

    override func tearDown() {
        harnesses.forEach { $0.cleanUp() }
        harnesses = []
    }

    private func document(version: Int = 1, params: String, experiments: String = "") -> String {
        let extra = experiments.isEmpty ? "" : #","experiments":[\#(experiments)]"#
        return #"{"version":\#(version),"etag":"\"v\#(version)-abc\"","params":[\#(params)]\#(extra)}"#
    }

    private let trialDays = #"{"k":"free_trial_days","t":"number","v":14,"r":10000}"#
    private let banner = #"{"k":"banner","t":"string","v":"hello","r":10000}"#
    private let iosOnly = #"{"k":"ios_only","t":"bool","v":false,"r":0,"o":{"ios":true,"android":false}}"#

    private func make(
        _ body: String?, consent: CorlexStartConsent = .granted, live: Bool = false, files: [String: String] = [:]
    ) -> Harness {
        var options = Harness.fastOptions()
        options.consent = consent
        options.config.live = live
        let harness = Harness(options: options, storedFiles: files) { transport in
            transport.responder = { request in
                guard request.url?.path == "/v1/config/document" else { return StubTransport.ok(202) }
                guard let body else { return StubTransport.ok(404) }
                return request.value(forHTTPHeaderField: "If-None-Match") == "\"v1-abc\"" && body.contains("v1-abc")
                    ? StubTransport.ok(304) : StubTransport.ok(200, body: body)
            }
        }
        harnesses.append(harness)
        return harness
    }

    private func configRequests(_ h: Harness) -> [URLRequest] {
        h.transport.requests.filter { $0.url?.path == "/v1/config/document" }
    }

    func testValuesAreEvaluatedOnTheDeviceAndRequestsCarryNoUserId() async {
        let h = make(document(params: "\(trialDays),\(banner),\(iosOnly)"))
        h.client.identify("user_secret_id", [:])
        await withCheckedContinuation { c in h.client.configReady { c.resume() } }
        XCTAssertEqual(h.client.configValue("free_trial_days", fallback: .int(7)), .int(14))
        XCTAssertEqual(h.client.configValue("banner", fallback: .string("")), .string("hello"))
        XCTAssertEqual(h.client.configValue("ios_only", fallback: .bool(false)), .bool(true), "override for ios beats a 0 % rollout")
        XCTAssertEqual(h.client.configValues().count, 3)
        let request = configRequests(h)[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Corlex-Key"), testSDKKey)
        XCTAssertFalse(request.url?.absoluteString.contains("user_secret_id") ?? true)
        XCTAssertNil(request.httpBody)
    }

    func testTypeMismatchAndMissingKeysGiveTheFallback() async {
        let h = make(document(params: trialDays))
        await withCheckedContinuation { c in h.client.configReady { c.resume() } }
        XCTAssertEqual(h.client.configValue("free_trial_days", fallback: .string("seven")), .string("seven"))
        XCTAssertEqual(h.client.configValue("nope", fallback: .bool(true)), .bool(true))
    }

    func testRolloutZeroReachesNobody() async {
        let h = make(document(params: #"{"k":"closed","t":"bool","v":true,"r":0}"#))
        await withCheckedContinuation { c in h.client.configReady { c.resume() } }
        XCTAssertEqual(h.client.configValue("closed", fallback: .bool(false)), .bool(false))
    }

    func testNoConsentNoDownload() {
        let h = make(document(params: trialDays), consent: .pending)
        h.settle()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(configRequests(h).isEmpty)
        XCTAssertEqual(h.client.configValue("free_trial_days", fallback: .int(7)), .int(7))
        XCTAssertEqual(h.diskFiles, [])
        h.client.optIn()
        wait(for: { !self.configRequests(h).isEmpty })
    }

    func testNewVersionWaitsForTheNextLaunchOnceAValueWasRead() async {
        let h = make(document(params: trialDays))
        await withCheckedContinuation { c in h.client.configReady { c.resume() } }
        XCTAssertEqual(h.client.configValue("free_trial_days", fallback: .int(7)), .int(14))
        h.transport.responder = { _ in
            StubTransport.ok(200, body: self.document(version: 2, params: #"{"k":"free_trial_days","t":"number","v":30,"r":10000}"#))
        }
        var updates: [CorlexConfigUpdate] = []
        _ = h.client.onConfigUpdate { updates.append($0) }
        await withCheckedContinuation { c in h.client.refreshConfig { c.resume() } }
        XCTAssertEqual(h.client.configValue("free_trial_days", fallback: .int(7)), .int(14), "never flips mid-session")
        wait(for: { updates.count == 1 })
        XCTAssertEqual(updates.first?.version, 2)
        XCTAssertEqual(updates.first?.applied, false)

        let next = Harness(options: Harness.fastOptions(), folder: h.folder)
        harnesses.append(next)
        XCTAssertEqual(next.client.configValue("free_trial_days", fallback: .int(7)), .int(30), "applied at the next launch, from disk")
    }

    func testLiveAppliesAtOnceAndAConditionalGetSendsTheEtag() async {
        let h = make(document(params: trialDays), live: true)
        await withCheckedContinuation { c in h.client.configReady { c.resume() } }
        _ = h.client.configValue("free_trial_days", fallback: .int(7))
        await withCheckedContinuation { c in h.client.refreshConfig { c.resume() } }
        let requests = configRequests(h)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1-abc\"")
        XCTAssertEqual(h.client.configValue("free_trial_days", fallback: .int(7)), .int(14), "304 keeps the saved document")
    }

    func testOfflineKeepsTheSavedDocument() {
        let saved = #"{"etag":"\"v1-abc\"","doc":\#(document(params: trialDays))}"#
        let h = make(nil, files: ["config.json": saved])
        h.settle()
        XCTAssertEqual(h.client.configValue("free_trial_days", fallback: .int(7)), .int(14))
    }

    func testOptOutErasesTheSavedConfig() async {
        let h = make(document(params: trialDays))
        await withCheckedContinuation { c in h.client.configReady { c.resume() } }
        XCTAssertTrue(h.diskFiles.contains("config.json"))
        h.client.optOut()
        h.settle()
        XCTAssertFalse(h.diskFiles.contains("config.json"))
        XCTAssertEqual(h.client.configValue("free_trial_days", fallback: .int(7)), .int(7))
    }

    func testExperimentAssignsAVariantAndExposesOncePerSession() async throws {
        let experiment = #"{"k":"paywall_test","s":"a1b2c3d4","v":[{"n":"control","b":5000,"v":0},{"n":"variant_1","b":10000,"v":1}]}"#
        let h = make(document(params: trialDays, experiments: experiment))
        await withCheckedContinuation { c in h.client.configReady { c.resume() } }
        let first = try XCTUnwrap(h.client.experiment("paywall_test"))
        let second = try XCTUnwrap(h.client.experiment("paywall_test"))
        XCTAssertEqual(first, second, "stable per person")
        XCTAssertNil(h.client.experiment("not_running"))
        wait(for: { h.transport.sentNames().contains("corlex.exposure") })
        h.settle()
        XCTAssertEqual(h.transport.sentNames().filter { $0 == "corlex.exposure" }.count, 1)
        let properties = h.transport.sentEvents.first { $0["name"] as? String == "corlex.exposure" }?["properties"] as? [String: Any]
        XCTAssertEqual(properties?["experiment"] as? String, "paywall_test")
        XCTAssertEqual(properties?["variant"] as? String, first.variant)
    }
}
