import Darwin
import XCTest
@testable import Corlex

final class DiagnosticsPrivacyTests: XCTestCase {
    private func output(_ action: () -> Void) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-diagnostics-\(UUID().uuidString)")
        let fd = open(file.path, O_CREAT | O_TRUNC | O_RDWR, 0o600)
        let saved = dup(STDOUT_FILENO)
        guard fd >= 0, saved >= 0 else { throw NSError(domain: "test stdout", code: 1) }
        defer {
            fflush(stdout)
            _ = dup2(saved, STDOUT_FILENO)
            close(saved); close(fd)
            try? FileManager.default.removeItem(at: file)
        }
        fflush(stdout)
        _ = dup2(fd, STDOUT_FILENO)
        action()
        fflush(stdout)
        return try String(contentsOf: file, encoding: .utf8)
    }
    func testRejectedNamesNeverLeakAndWarningBudgetIsBounded() throws {
        var options = Harness.fastOptions()
        options.consent = .pending
        let harness = Harness(options: options)
        defer { harness.cleanUp() }
        let text = try output {
            for index in 0..<1000 { harness.client.track("person\(index)@example.test", [:]) }
            harness.settle()
        }
        XCTAssertFalse(text.contains("@example.test"))
        XCTAssertEqual(text.components(separatedBy: "invalid_event_name").count - 1, 1)
        XCTAssertTrue(harness.transport.requests.isEmpty)
    }
}
