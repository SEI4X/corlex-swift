import Foundation
import XCTest
@testable import Corlex

final class StorageBindingTests: XCTestCase {
    private let key = "ck_test_" + String(repeating: "x", count: 43)
    private let ingest = URL(string: "https://ingest.example.test")!
    private let config = URL(string: "https://config.example.test")!

    func testDigestMatchesExactJSONTupleAndIndependentSHA256Vector() {
        XCTAssertEqual(StorageBinding.digest(key: key, endpoint: ingest, configEndpoint: config), "2e940110f634ae30dc358a01db9879196e84898b4f83a53e6e6e1b550642d8d0")
        XCTAssertEqual(StorageBinding.digest(key: key, endpoint: URL(string: "https://INGEST.example.test:443///")!, configEndpoint: URL(string: "https://CONFIG.example.test:443/")!), StorageBinding.digest(key: key, endpoint: ingest, configEndpoint: config))
        XCTAssertEqual(StorageBinding.canonical(URL(string: "https://ingest.example.test/cell-a/")!), "https://ingest.example.test/cell-a")
        XCTAssertNotEqual(StorageBinding.digest(key: key, endpoint: URL(string: "https://ingest.example.test/cell-a")!, configEndpoint: config), StorageBinding.digest(key: key, endpoint: URL(string: "https://ingest.example.test/cell-b")!, configEndpoint: config))
    }
    func testInvalidCredentialsAndEndpointsCannotBind() {
        for value in ["", "cm_example", "sk-example", key + "x", key + "\n", "ck_test_" + String(repeating: "x", count: 42) + "-"] { XCTAssertFalse(StorageBinding.validKey(value)) }
        XCTAssertNil(StorageBinding.digest(key: key, endpoint: URL(string: "https://user:secret@example.test")!, configEndpoint: config))
        XCTAssertNil(StorageBinding.digest(key: key, endpoint: URL(string: "http://example.test")!, configEndpoint: config))
    }
}
