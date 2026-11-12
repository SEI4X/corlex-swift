import Foundation
import XCTest
@testable import Corlex

final class EndpointPolicyTests: XCTestCase {
    #if os(iOS)
    func testInvalidEndpointDoesNotInitializeOrPersistTheSDK() throws {
        Corlex.stopForTesting()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-invalid-endpoint-\(UUID().uuidString)")
        defer { Corlex.stopForTesting(); try? FileManager.default.removeItem(at: folder) }
        let transport = StubTransport()
        let environment = ClientEnvironment(storage: Storage(directory: folder), transport: transport, device: testDevice,
            trackingStatus: { .granted }, now: Date.init, installGlobalHooks: false, backoff: Backoff())
        var options = CorlexOptions()
        options.endpoint = try XCTUnwrap(URL(string: "http://public.example.test/private"))
        Corlex.start(key: testSDKKey, options: options, environment: environment)
        Corlex.client?.queue.sync {}
        XCTAssertNil(Corlex.client)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
    #endif

    func testSecureAndLoopbackOriginsPreserveReverseProxyPaths() throws {
        for text in ["https://api.example/prefix", "http://localhost:3102/path", "http://127.15.0.1", "http://[::1]", "http://10.0.2.2", "http://10.0.3.2"] {
            XCTAssertTrue(EndpointPolicy.allowed(try XCTUnwrap(URL(string: text))), text)
        }
        let url = try XCTUnwrap(URL(string: "https://api.example/prefix"))
        XCTAssertEqual(url.appendingPathComponent("v1/batch").path, "/prefix/v1/batch")
    }
    func testExternalHTTPRequiresExplicitDevelopmentPermission() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.1.2/prefix"))
        XCTAssertFalse(EndpointPolicy.allowed(url))
        XCTAssertTrue(EndpointPolicy.allowed(url, allowInsecureHttp: true))
    }
    func testCredentialsAndMetadataAreRejectedEvenWithDevelopmentOverride() throws {
        for text in ["https://user:secret@example.test", "https://@example.test", "https://example.test?key=secret", "https://example.test#fragment", "file:///tmp/file", "http://127.evil.test"] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertFalse(EndpointPolicy.allowed(url), text)
            if !text.contains("127.evil") { XCTAssertFalse(EndpointPolicy.allowed(url, allowInsecureHttp: true), text) }
        }
    }
}
