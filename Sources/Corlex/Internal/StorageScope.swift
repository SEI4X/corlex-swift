import Foundation

/// Shared by one runtime's storage users. Pending→granted can retain that same generation;
/// denied/stale runtimes receive a new scope object and cannot gain access again.
final class StorageScope {
    let ledger: PrivacyLedger
    let owner: String
    private let lock = NSLock()
    private var snapshot: PrivacyRecord

    init(ledger: PrivacyLedger, owner: String, record: PrivacyRecord) {
        self.ledger = ledger
        self.owner = owner
        self.snapshot = record
    }

    var record: PrivacyRecord {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    var isCurrent: Bool { ledger.current() == record }

    func grantSameGeneration(_ granted: PrivacyRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard snapshot.state == .pending, granted.state == .granted,
              snapshot.generation == granted.generation, ledger.current() == granted else { return false }
        snapshot = granted
        return true
    }

    func authorized<T>(_ action: () -> T) -> T? {
        ledger.authorized(record: record, action)
    }
}
