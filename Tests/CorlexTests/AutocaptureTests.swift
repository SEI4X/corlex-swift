import SwiftUI
import UIKit
import XCTest
@testable import Corlex

final class ProfileViewController: UIViewController {}

final class NamedViewController: UIViewController, CorlexScreenNaming {
    var corlexScreenName: String { "Custom Name" }
}

final class AutocaptureTests: XCTestCase {
    private let testBundle = Bundle(for: ProfileViewController.self)

    func testScreenNameIsTheClassNameOfAppControllersOnly() {
        XCTAssertEqual(ScreenTracker.screenName(of: ProfileViewController(), appBundle: testBundle), "ProfileViewController")
        XCTAssertEqual(ScreenTracker.screenName(of: NamedViewController(), appBundle: testBundle), "Custom Name")
        XCTAssertNil(ScreenTracker.screenName(of: UINavigationController(), appBundle: testBundle), "containers are not screens")
        XCTAssertNil(ScreenTracker.screenName(of: UITabBarController(), appBundle: testBundle))
        XCTAssertNil(ScreenTracker.screenName(of: UIViewController(), appBundle: .main), "not the app's own bundle")
        XCTAssertNil(ScreenTracker.screenName(of: UIHostingController(rootView: Text("x")), appBundle: testBundle), "SwiftUI names screens itself")
    }

    func testSwizzleReportsViewDidAppearAndCanBeSwitchedOff() {
        var seen: [String] = []
        ScreenTracker.start { seen.append($0) }
        let controller = NamedViewController()
        controller.viewDidAppear(false)
        XCTAssertEqual(seen, ["Custom Name"])
        // The original implementation still runs: UIKit's own viewDidAppear is reached.
        ScreenTracker.stop()
        controller.viewDidAppear(false)
        XCTAssertEqual(seen, ["Custom Name"], "off means silent")
        ScreenTracker.start { seen.append($0) }
        ScreenTracker.start { seen.append("again:\($0)") }  // a second start must not swap twice
        controller.viewDidAppear(false)
        XCTAssertEqual(seen, ["Custom Name", "again:Custom Name"])
        ScreenTracker.stop()
    }

    func testLifecycleNotificationsReachTheHandlers() {
        let center = NotificationCenter()
        var events: [String] = []
        let lifecycle = Lifecycle(
            handlers: .init(
                didEnterBackground: { events.append("bg") },
                willEnterForeground: { events.append("fg") },
                didBecomeActive: { events.append("active") }
            ),
            center: center
        )
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(events, ["bg", "fg", "active"])
        lifecycle.stop(center: center)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(events.count, 3)
    }

    func testDeviceInfoFormatsLikeTheProtocol() {
        XCTAssertEqual(DeviceInfo.osVersionString(.init(majorVersion: 18, minorVersion: 3, patchVersion: 0)), "18.3")
        XCTAssertEqual(DeviceInfo.osVersionString(.init(majorVersion: 18, minorVersion: 3, patchVersion: 1)), "18.3.1")
        let info = DeviceInfo.current()
        XCTAssertFalse(info.deviceModel.isEmpty)
        XCTAssertFalse(info.locale.contains("_"))
        XCTAssertEqual(info.context.platform, "ios")
    }

    func testPublicFacadeStartsOnceAndReadsFlags() {
        Corlex.stopForTesting()
        defer { Corlex.stopForTesting() }
        let transport = DeferredFacadeTransport()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-facade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let env = ClientEnvironment(
            storage: Storage(directory: folder), transport: transport, device: testDevice,
            trackingStatus: { .pending }, now: Date.init, installGlobalHooks: false, backoff: Backoff()
        )
        Corlex.start(key: testSDKKey, options: Harness.fastOptions(), environment: env)
        wait(for: { transport.hasPendingConfig })
        XCTAssertTrue(Corlex.flag("on", default: false) == false, "before the first download: the default")
        transport.deliverConfig(StubTransport.ok(200, body: #"{"version":1,"etag":"\"v1-a\"","params":[{"k":"on","t":"bool","v":true,"r":10000},{"k":"n","t":"number","v":2.5,"r":10000},{"k":"s","t":"string","v":"x","r":10000},{"k":"j","t":"json","v":{"a":[1]},"r":10000}]}"#))
        let ready = expectation(description: "ready")
        Task { await Corlex.config.ready(); ready.fulfill() }
        wait(for: [ready], timeout: 3)
        XCTAssertTrue(Corlex.flag("on", default: false))
        XCTAssertEqual(Corlex.flag("n", default: 1.0), 2.5)
        XCTAssertEqual(Corlex.flag("n", default: 1), 1, "2.5 is not an Int: the default")
        XCTAssertEqual(Corlex.flag("s", default: ""), "x")
        XCTAssertEqual(Corlex.config.get("j", default: [String: Any]())["a"] as? [Int], [1])
        XCTAssertEqual(Corlex.flag("missing", default: 7), 7)
        Corlex.track("tap", properties: ["n": 1])
        let flushed = expectation(description: "flush")
        Task { await Corlex.flush(); flushed.fulfill() }
        wait(for: [flushed], timeout: 3)
        XCTAssertEqual(transport.sentNames(), ["tap"])
        XCTAssertEqual(Corlex.consent, .granted)
    }
}
