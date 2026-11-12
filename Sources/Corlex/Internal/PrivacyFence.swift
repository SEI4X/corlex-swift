import Foundation

/// Process-local refusal wins immediately even when durable privacy I/O is unavailable.
/// Entries disappear after a successful publication; no credentials or captured data live here.
private enum PrivacyFenceRegistry {
    static let lock = NSLock()
    static var records: [String: PrivacyRecord] = [:]
}

extension PrivacyLedger {
    func memoryFence() -> PrivacyRecord? {
        PrivacyFenceRegistry.lock.lock()
        defer { PrivacyFenceRegistry.lock.unlock() }
        return PrivacyFenceRegistry.records[root.standardizedFileURL.path]
    }

    func replaceMemoryFence(expected: PrivacyRecord?, with record: PrivacyRecord?) -> Bool {
        PrivacyFenceRegistry.lock.lock()
        defer { PrivacyFenceRegistry.lock.unlock() }
        let key = root.standardizedFileURL.path
        guard PrivacyFenceRegistry.records[key] == expected else { return false }
        PrivacyFenceRegistry.records[key] = record
        return true
    }

    func clearMemoryFence(expected: PrivacyRecord?) {
        PrivacyFenceRegistry.lock.lock()
        defer { PrivacyFenceRegistry.lock.unlock() }
        let key = root.standardizedFileURL.path
        if PrivacyFenceRegistry.records[key] == expected { PrivacyFenceRegistry.records[key] = nil }
    }

    func setMemoryFence(_ record: PrivacyRecord?) {
        PrivacyFenceRegistry.lock.lock()
        defer { PrivacyFenceRegistry.lock.unlock() }
        PrivacyFenceRegistry.records[root.standardizedFileURL.path] = record
    }
}
