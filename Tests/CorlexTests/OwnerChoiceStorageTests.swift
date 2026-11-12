import XCTest
@testable import Corlex

final class OwnerChoiceStorageTests: XCTestCase {
    private var root: URL!
    private let owner = String(repeating: "a", count: 64)
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-owner-book-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testMalformedDuplicateOversizedAndNoncanonicalMarkersCannotFallbackToLegacyGrant() throws {
        let book = OwnerChoices(root: root)
        XCTAssertTrue(book.grant(owner))
        let legacy = root.appendingPathComponent("bound-consent")
        try Data("granted".utf8).write(to: legacy)
        let row = "{\"choice\":\"granted\",\"owner\":\"\(owner)\"}"
        let invalid = ["broken", "", "[\(row),\(row)]", "[\(row.dropLast()),\"choice\":\"granted\"}]",
                       "[\(row.replacingOccurrences(of: "granted", with: "pending"))]",
                       "[\(row.replacingOccurrences(of: "granted", with: "denied"))]",
                       "[\(row.dropLast()),\"secret\":\"not-accepted\"}]", " [\(row)]", String(repeating: " ", count: 32 * 1024 + 1)]
        for text in invalid {
            try Data(text.utf8).write(to: root.appendingPathComponent("owner-choices.json"))
            XCTAssertFalse(book.contains(owner, legacy: legacy))
        }
    }

    func testBoundedBookDoesNotEvictAnotherOwnersChoiceAndIsBackupExcluded() throws {
        let book = OwnerChoices(root: root)
        for index in 0..<256 { XCTAssertTrue(book.grant(String(format: "%064x", index))) }
        XCTAssertFalse(book.grant(owner))
        XCTAssertTrue(book.contains(String(format: "%064x", 0)))
        let path = root.appendingPathComponent("owner-choices.json")
        XCTAssertLessThanOrEqual(try Data(contentsOf: path).count, 32 * 1024)
        XCTAssertEqual(try path.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testBookSymlinkIsNotReadAndExplicitReplacementDoesNotTouchHostFile() throws {
        let book = OwnerChoices(root: root)
        XCTAssertTrue(book.grant(owner))
        let path = root.appendingPathComponent("owner-choices.json")
        let bytes = try Data(contentsOf: path)
        let host = root.appendingPathComponent("host-file")
        try bytes.write(to: host)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: host)
        XCTAssertFalse(book.contains(owner))
        XCTAssertTrue(book.grant(owner))
        XCTAssertEqual(try Data(contentsOf: host), bytes)
        XCTAssertFalse((try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true)
    }

    func testStaleRecordCannotSaveChoiceAfterImmediateRefusal() throws {
        let ledger = PrivacyLedger(root: root)
        let first = try XCTUnwrap(ledger.prepare(requested: .granted))
        _ = ledger.revoke()
        XCTAssertFalse(ledger.rememberChoice(owner: owner, expected: first))
        XCTAssertFalse(OwnerChoices(root: root).contains(owner))
    }
}
