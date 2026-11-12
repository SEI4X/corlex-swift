import XCTest
@testable import Corlex

final class NativeCrashPrivacyTests: XCTestCase {
    private func report(_ values: [String: Any] = [:], frames: String = "") throws -> Data {
        var header: [String: Any] = ["crash_id": "0192f3a0-0000-7000-8000-000000000001", "timestamp_ms": 1000,
            "name": "person@example.test", "message": "private-user-token", "source": "ns_exception"]
        header.merge(values) { _, next in next }
        return try JSONSerialization.data(withJSONObject: header) + Data(("\n" + frames).utf8)
    }
    func testLegacyFreeTextDoesNotBypassDefaultPrivacy() throws {
        let crash = try XCTUnwrap(CrashReportReader.parse(try report()))
        XCTAssertEqual(crash.properties["name"], .string("NativeError"))
        XCTAssertEqual(crash.properties["message"], .string("Error details omitted"))
        XCTAssertEqual(crash.appVersion, "")
        XCTAssertEqual(crash.build, "")
    }
    func testOriginalReleaseMetadataIsExactOrUnknownNeverAPrefix() throws {
        let version = String(repeating: "x", count: 124) + "😀"
        let valid = try XCTUnwrap(CrashReportReader.parse(try report(["app_version": version, "build": String(repeating: "b", count: 32)])))
        XCTAssertEqual(valid.appVersion, version)
        XCTAssertEqual(valid.build?.utf8.count, 32)
        let invalid = try XCTUnwrap(CrashReportReader.parse(try report(["app_version": version + "x", "build": String(repeating: "b", count: 33)])))
        XCTAssertEqual(invalid.appVersion, "")
        XCTAssertEqual(invalid.build, "")
    }
    func testMalformedTimestampsAndIdsAreRejectedBeforeDateFormatting() throws {
        for value in [true, -1, 1e300] as [Any] { XCTAssertNil(CrashReportReader.parse(try report(["timestamp_ms": value]))) }
        XCTAssertNil(CrashReportReader.parse(try report(["crash_id": "bad-id"])))
    }
    func testLegacyFramePathsAndUnboundedAddressesCannotLeak() throws {
        let frames = "F\t-\t0x0\t0x123\t/Users/private/MyApp\t/Users/private/person@example.test\nF\t-\t0x0\t0x" + String(repeating: "a", count: 100) + "\tMyApp\n"
        let crash = try XCTUnwrap(CrashReportReader.parse(try report(frames: frames)))
        guard case .array(let list) = crash.properties["frames"], case .object(let frame) = list.first else { return XCTFail("missing safe frame") }
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(frame["image"], .string("MyApp"))
        XCTAssertNil(frame["fn"])
    }
}
