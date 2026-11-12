import XCTest
@testable import Corlex

final class ClientTests: XCTestCase {
    private var harnesses: [Harness] = []

    private func make(
        consent: CorlexStartConsent = .granted,
        autocapture: CorlexAutocapture = .none,
        files: [String: String] = [:],
        att: CorlexConsent = .pending
    ) -> Harness {
        var options = Harness.fastOptions()
        options.consent = consent
        options.autocapture = autocapture
        let harness = Harness(options: options, storedFiles: files, att: att)
        harnesses.append(harness)
        return harness
    }

    override func tearDown() {
        harnesses.forEach { $0.cleanUp() }
        harnesses = []
    }

    // MARK: - Event shape

    func testEventCarriesContextBuildAndIdentity() throws {
        let h = make()
        h.client.track("purchase", ["plan": .string("pro")])
        wait(for: { !h.transport.sentEvents.isEmpty })
        let event = try XCTUnwrap(h.transport.sentEvents.first)
        XCTAssertEqual(event["name"] as? String, "purchase")
        XCTAssertNotNil(UUID(uuidString: event["event_id"] as? String ?? ""))
        XCTAssertTrue((event["anonymous_id"] as? String ?? "").hasPrefix("a_"))
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        XCTAssertEqual(context["platform"] as? String, "ios")
        XCTAssertEqual(context["app_version"] as? String, "1.4.2")
        XCTAssertEqual(context["os"] as? String, "iOS")
        XCTAssertEqual(context["os_version"] as? String, "18.3")
        XCTAssertEqual(context["device_model"] as? String, "iPhone16,2")
        XCTAssertEqual(context["locale"] as? String, "en-US")
        XCTAssertEqual((context["sdk"] as? [String: String])?["name"], "corlex-swift")
        let properties = try XCTUnwrap(event["properties"] as? [String: Any])
        XCTAssertEqual(properties["build"] as? String, "87")
        XCTAssertEqual(properties["plan"] as? String, "pro")
    }

    func testTheSDKOwnsTheBuildProperty() throws {
        let h = make()
        h.client.track("tap", ["build": .string("hacked")])
        wait(for: { !h.transport.sentEvents.isEmpty })
        XCTAssertEqual((h.transport.sentEvents[0]["properties"] as? [String: Any])?["build"] as? String, "87")
    }

    func testAppOpenAndScreenViewWithPreviousScreen() {
        var auto = CorlexAutocapture.none
        auto.appOpen = true
        let h = make(autocapture: auto)
        h.client.screen("Home", [:], source: "swiftui")
        h.client.screen("Settings", [:], source: "uikit")
        wait(for: { h.transport.sentNames().count == 3 })
        XCTAssertEqual(h.transport.sentNames(), ["app_open", "screen_view", "screen_view"])
        let second = h.transport.sentEvents[2]["properties"] as? [String: Any]
        XCTAssertEqual(second?["screen"] as? String, "Settings")
        XCTAssertEqual(second?["previous_screen"] as? String, "Home")
        XCTAssertEqual(second?["source"] as? String, "uikit")
    }

    func testIdentifyLinksBothIdsAndSurvivesARestart() throws {
        let h = make()
        h.client.identify("user_42", ["plan": .string("pro")])
        h.client.track("after")
        wait(for: { h.transport.sentNames().count == 2 })
        let identify = h.transport.sentEvents[0]
        XCTAssertEqual(identify["name"] as? String, "corlex.identify")
        XCTAssertEqual(identify["user_id"] as? String, "user_42")
        XCTAssertNotNil(identify["anonymous_id"])
        XCTAssertEqual(h.transport.sentEvents[1]["user_id"] as? String, "user_42")
        h.settle()
        let again = Identity(storage: h.storage, persisted: true)
        XCTAssertEqual(again.userId, "user_42")
        XCTAssertEqual(again.anonymousId, identify["anonymous_id"] as? String)
    }

    func testResetStartsANewAnonymousPerson() throws {
        let h = make()
        h.client.identify("user_1", [:])
        h.client.track("a")
        h.client.reset()
        h.client.track("b")
        wait(for: { h.transport.sentNames().count == 3 })
        let first = h.transport.sentEvents[1]
        let last = h.transport.sentEvents[2]
        XCTAssertNil(last["user_id"])
        XCTAssertNotEqual(first["anonymous_id"] as? String, last["anonymous_id"] as? String)
    }

    func testInvalidNameIsNotSent() {
        let h = make()
        h.client.track("Bad Name", [:])
        h.client.track("good_name", [:])
        wait(for: { !h.transport.sentNames().isEmpty })
        XCTAssertEqual(h.transport.sentNames(), ["good_name"])
    }

    // MARK: - Consent

    func testPendingConsentMakesNoRequestAndWritesNothing() {
        let h = make(consent: .pending)
        h.client.track("tap", [:])
        h.client.identify("u1", [:])
        Thread.sleep(forTimeInterval: 0.2)
        h.settle()
        XCTAssertTrue(h.transport.requests.isEmpty, "not even a config download")
        XCTAssertEqual(h.diskFiles, [], "no captured data on disk; privacy bookkeeping is separate")
        XCTAssertEqual(h.client.currentConsent(), .pending)
    }

    func testOptInSendsWhatWaitedInOrderAndStoresTheChoice() {
        let h = make(consent: .pending)
        h.client.track("first", [:])
        h.client.track("second", [:])
        h.settle()
        h.client.optIn()
        wait(for: { h.transport.sentNames().count == 2 })
        XCTAssertEqual(h.transport.sentNames(), ["first", "second"])
        XCTAssertEqual(h.storage.readText("consent"), "granted")
        XCTAssertTrue(h.diskFiles.contains("anonymous_id"))
    }

    func testOptOutWipesEverythingAndTheChoiceSurvivesARestart() {
        let h = make(files: ["queue.jsonl": "", "anonymous_id": "a_old"])
        h.client.track("tap", [:])
        wait(for: { !h.transport.sentEvents.isEmpty })
        h.client.optOut()
        h.client.track("after_opt_out", [:])
        h.settle()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(h.transport.sentNames(), ["tap"])
        XCTAssertEqual(h.diskFiles, [], "all captured-data scopes are erased")
        XCTAssertEqual(PrivacyLedger(root: h.folder.appendingPathComponent("sdk-ios")).current()?.state, .denied)

        let restarted = Harness(options: Harness.fastOptions(), folder: h.folder)
        restarted.client.track("silent", [:])
        restarted.settle()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(restarted.transport.requests.isEmpty)
        XCTAssertEqual(restarted.client.currentConsent(), .denied)
    }

    func testAttFollowsTheStatusAndNeverShowsAPrompt() {
        XCTAssertEqual(make(consent: .att, att: .pending).client.currentConsent(), .pending)
        XCTAssertEqual(make(consent: .att, att: .granted).client.currentConsent(), .granted)
        let denied = make(consent: .att, att: .denied)
        XCTAssertEqual(denied.client.currentConsent(), .denied)
        denied.client.track("x", [:])
        denied.settle()
        XCTAssertTrue(denied.transport.requests.isEmpty)
    }

    func testAnExplicitChoiceBeatsTheStartOption() {
        XCTAssertEqual(make(consent: .granted, files: ["consent": "denied"]).client.currentConsent(), .denied)
        XCTAssertEqual(make(consent: .pending, files: ["consent": "granted"]).client.currentConsent(), .granted)
    }

    func testPersistedQueueIsSentAfterARestartWithTheSameEventIds() throws {
        let h = make()
        h.transport.responder = { _ in StubTransport.ok(503) }
        h.client.track("offline_event", [:])
        wait(for: { !h.transport.batches.isEmpty })
        h.settle()
        let firstId = h.transport.sentEvents.first?["event_id"] as? String

        let restarted = Harness(options: Harness.fastOptions(), folder: h.folder)
        wait(for: { !restarted.transport.sentEvents.isEmpty })
        XCTAssertEqual(restarted.transport.sentEvents.first?["event_id"] as? String, firstId)
        harnesses.append(restarted)
    }
}
