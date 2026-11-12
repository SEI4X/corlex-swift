import Foundation

/// Owner activation and SDK choice. The platform's live privacy status is only a ceiling.
final class ClientBinding {
    private let lock = NSRecursiveLock()
    private let refusal = ImmediateRefusal()
    private let ledger: PrivacyLedger?
    private let owner: String
    private let ceilingOf: () -> PrivacyRecord.State
    private var ceiling: PrivacyRecord.State
    private var snapshot: PrivacyRecord?
    private var selected: StorageScope?
    private var sdkChoice: PrivacyRecord.State
    private var effective: PrivacyRecord.State
    private var memory = false
    private var memoryAnchor: PrivacyRecord?
    private var activation = UUID()

    struct Options {
        var owner: String
        var legacy: Storage?
        var requested: PrivacyRecord.State
        var ceilingOf: () -> PrivacyRecord.State = { .granted }
    }
    convenience init(owner: String, legacy: Storage?, requested: PrivacyRecord.State) {
        self.init(Options(owner: owner, legacy: legacy, requested: requested))
    }
    init(_ options: Options) {
        let owner = options.owner, legacy = options.legacy, requested = options.requested
        self.owner = owner
        self.ceilingOf = options.ceilingOf
        ceiling = options.ceilingOf()
        ledger = legacy.map { PrivacyLedger(root: $0.directory.appendingPathComponent("sdk-ios")) }
        let activated = ledger?.activate(.init(owner: owner, requested: requested, legacy: legacy?.readText("consent"), ceiling: ceiling))
        snapshot = activated?.record
        sdkChoice = activated?.choice ?? .pending
        effective = .restrict(sdkChoice, by: snapshot?.state ?? .pending)
        if let ledger, let snapshot {
            let scope = StorageScope(ledger: ledger, owner: owner, record: snapshot)
            selected = scope
            for name in ["anonymous_id", "user_id", "queue.jsonl", "config.json", "consent"] { legacy?.remove(name) }
            if let old = legacy?.directory.appendingPathComponent("crashes") { try? FileManager.default.removeItem(at: old) }
        }
    }

    var storage: Storage? { locked { selected.flatMap(Storage.bound(scope:)) } }
    var state: PrivacyRecord.State { refusal.current != nil ? .denied : locked { refusal.current != nil ? .denied : effective } }
    var refusalToken: PrivacyRecord? { refusal.current }
    var token: UUID { locked { activation } }
    var ceilingChanged: Bool { locked { ceilingOf() != ceiling } }
    var isCurrent: Bool {
        guard refusal.current == nil else { return false }
        return locked {
            guard ceilingOf() == ceiling else { return false }
            if memory { return ledger?.current() == memoryAnchor && refusal.current == nil }
            guard let snapshot else { return false }
            return ledger?.current() == snapshot && refusal.current == nil
        }
    }
    var canSend: Bool { refusal.current == nil && locked { effective == .granted && isCurrent } }

    /// Preserve only an SDK-pending RAM session whose privacy generation did not change.
    func grant(beforePublish: () -> Void = {}) -> Bool {
        grant(ifRefusal: refusal.current, beforePublish: beforePublish)
    }

    func grant(ifRefusal expected: PrivacyRecord?, beforePublish: () -> Void = {}) -> Bool {
        guard refusal.current == expected else { return false }
        return locked {
            let keep = effective == .pending && isCurrent && !memory
            let current = ledger?.current()
            guard refusal.current == expected else { return false }
            ceiling = ceilingOf()
            sdkChoice = .granted
            if let ledger, let current, let granted = ledger.grant(expected: current, ceiling: ceiling, beforePublish: beforePublish) {
                let same = keep && selected?.record.generation == granted.generation
                if same, let selected {
                    if selected.record.state == .pending { _ = selected.grantSameGeneration(granted) }
                } else {
                    selected = StorageScope(ledger: ledger, owner: owner, record: granted)
                    activation = UUID()
                }
                snapshot = granted
                memory = false
                effective = granted.state
                refusal.clear(expected: expected)
                _ = ledger.rememberChoice(owner: owner, expected: granted)
                storage?.writeText("granted", to: "consent")
                return same
            }
            selected = nil
            snapshot = nil
            memoryAnchor = ledger?.current()
            memory = true
            effective = .restrict(.granted, by: ceiling)
            activation = UUID()
            refusal.clear(expected: expected)
            return false
        }
    }

    func rememberChoice(ifRefusal expected: PrivacyRecord?) {
        guard refusal.current == expected else { return }
        locked {
            guard refusal.current == expected, let snapshot else { return }
            _ = ledger?.rememberChoice(owner: owner, expected: snapshot)
        }
    }

    /// Effective ceiling changes always create a fresh activation, never resume old RAM.
    func observeCeiling(beforePublish: () -> Void = {}) -> Bool {
        locked {
            let next = ceilingOf()
            guard next != ceiling else { return false }
            if memory {
                guard ledger?.current() == memoryAnchor else { return false }
                beforePublish()
                ceiling = next
                effective = .restrict(sdkChoice, by: next)
                activation = UUID()
                return true
            }
            guard let ledger, let snapshot,
                  let updated = ledger.observe(expected: snapshot, ceiling: next, beforePublish: beforePublish) else { return false }
            ceiling = next
            self.snapshot = updated
            effective = .restrict(sdkChoice, by: updated.state)
            if updated.generation == snapshot.generation { return false }
            selected = StorageScope(ledger: ledger, owner: owner, record: updated)
            activation = UUID()
            return true
        }
    }

    func revoke() {
        completeRevocation(expected: beginRevocation())
    }

    /// Only short memory locks: callable before transport callbacks or filesystem cleanup.
    func beginRevocation() -> PrivacyRecord {
        let record = PrivacyRecord(generation: UUID().uuidString.lowercased(), state: .denied)
        refusal.publish(record) { ledger?.setMemoryFence(record) }
        return record
    }

    /// Runs on the SDK queue. The immediate refusal already blocks every old entrypoint.
    func completeRevocation(expected: PrivacyRecord) {
        locked {
            guard refusal.current == expected else { return }
            sdkChoice = .denied
            effective = .denied
            memory = false
            activation = UUID()
            snapshot = ledger?.completeRevocation(expected: expected)
            selected = nil
        }
    }

    func invalidate() {
        locked {
            effective = .pending
            snapshot = nil
            selected = nil
            memory = false
            activation = UUID()
        }
    }

    private func locked<T>(_ action: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return action()
    }
}

/// Never held across filesystem, binding, reporter or transport operations.
private final class ImmediateRefusal {
    private let lock = NSLock()
    private var value: PrivacyRecord?
    var current: PrivacyRecord? { lock.lock(); defer { lock.unlock() }; return value }
    func publish(_ record: PrivacyRecord, memoryFence: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        value = record
        memoryFence()
    }
    func clear(expected: PrivacyRecord?) {
        lock.lock(); defer { lock.unlock() }
        if value == expected { value = nil }
    }
}
