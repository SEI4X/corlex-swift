import Darwin
import Foundation

struct PrivacyRecord: Codable, Equatable {
    enum State: String, Codable {
        case granted, pending, denied
        var restriction: Int { self == .denied ? 2 : self == .pending ? 1 : 0 }
        static func restrict(_ choice: State, by ceiling: State) -> State {
            choice.restriction >= ceiling.restriction ? choice : ceiling
        }
    }
    let generation: String
    let state: State
    let sdkChoice: State
    var valid: Bool { generation.utf8.count == 36 && UUID(uuidString: generation) != nil && state.restriction >= sdkChoice.restriction }
    init(generation: String, state: State, sdkChoice: State? = nil) {
        self.generation = generation; self.state = state; self.sdkChoice = sdkChoice ?? state
    }
    enum CodingKeys: String, CodingKey { case generation, state, sdkChoice }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: Key.self)
        let keys = Set(all.allKeys.map(\.stringValue))
        let expected: Set<String> = keys.contains("sdkChoice") ? ["generation", "state", "sdkChoice"] : ["generation", "state"]
        guard keys == expected else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid SDK privacy shape")) }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        generation = try values.decode(String.self, forKey: .generation)
        state = try values.decode(State.self, forKey: .state)
        sdkChoice = values.contains(.sdkChoice) ? try values.decode(State.self, forKey: .sdkChoice) : state
    }
}

/// The SDK-only privacy fence lives outside credential scopes. All scope I/O rechecks it
/// under this same filesystem lock; a delayed writer cannot recreate revoked state.
final class PrivacyLedger {
    let root: URL
    private let mutex = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(root: URL) { self.root = root }

    func current() -> PrivacyRecord? {
        if let fence = memoryFence() { return fence }
        return locked { readRecord() } ?? nil
    }

    struct ActivationOptions {
        var owner: String
        var requested: PrivacyRecord.State
        var legacy: String?
        var ceiling: PrivacyRecord.State
    }
    struct Activation { let record: PrivacyRecord; let choice: PrivacyRecord.State }

    func activate(_ options: ActivationOptions) -> Activation? {
        locked {
            guard OwnerChoices.valid(options.owner), let record = prepared(requested: options.requested, legacy: options.legacy, ceiling: options.ceiling) else { return nil }
            let choices = OwnerChoices(root: root)
            let legacy = record.state == .granted ? scope(owner: options.owner, record: record)?.appendingPathComponent("consent") : nil
            let retained = choices.contains(options.owner, legacy: legacy)
            if options.requested == .pending && record.sdkChoice == .granted && !retained {
                guard let pending = publish(choice: .pending, ceiling: options.ceiling, fence: memoryFence()) else { return nil }
                return Activation(record: pending, choice: .pending)
            }
            let choice = record.sdkChoice == .granted ? (retained ? .granted : options.requested) : record.sdkChoice
            return Activation(record: record, choice: choice)
        } ?? nil
    }

    func prepare(requested: PrivacyRecord.State, legacy: String? = nil, ceiling: PrivacyRecord.State = .granted) -> PrivacyRecord? {
        locked { prepared(requested: requested, legacy: legacy, ceiling: ceiling) } ?? nil
    }

    private func prepared(requested: PrivacyRecord.State, legacy: String?, ceiling: PrivacyRecord.State) -> PrivacyRecord? {
        let fence = memoryFence()
        switch readStatus() {
        case .valid(let record):
            if requested == .denied && record.sdkChoice != .denied { return publish(choice: .denied, ceiling: ceiling, fence: fence) }
            return observeRecord(record, ceiling: ceiling, fence: fence)
        case .missing:
            let choice = legacy == "denied" ? PrivacyRecord.State.denied : legacy == "pending" ? .pending : requested
            return publish(choice: choice, ceiling: ceiling, fence: fence)
        case .invalid: return nil
        }
    }

    func rememberChoice(owner: String, expected: PrivacyRecord) -> Bool {
        locked {
            guard readRecord() == expected, expected.sdkChoice == .granted else { return false }
            return OwnerChoices(root: root).grant(owner) && readRecord() == expected
        } ?? false
    }

    func grant(expected: PrivacyRecord, ceiling: PrivacyRecord.State = .granted,
               beforePublish: () -> Void = {}) -> PrivacyRecord? {
        locked {
            let fence = memoryFence()
            guard readRecord() == expected else { return nil }
            if expected.sdkChoice != .granted && !OwnerChoices(root: root).clear() { return nil }
            let observed = PrivacyRecord.State.restrict(expected.sdkChoice, by: ceiling)
            let fresh = expected.state == .denied || observed != expected.state
            let generation = fresh ? UUID().uuidString.lowercased() : expected.generation
            let record = PrivacyRecord(generation: generation, state: .restrict(.granted, by: ceiling), sdkChoice: .granted)
            if record != expected { beforePublish() }
            return publishRecord(record, fence: fence, wipe: fresh)
        } ?? nil
    }

    /// ATT is a ceiling, never a replacement for the app's own consent choice.
    func observe(expected: PrivacyRecord, ceiling: PrivacyRecord.State, beforePublish: () -> Void = {}) -> PrivacyRecord? {
        locked {
            let fence = memoryFence()
            guard readRecord() == expected else { return nil }
            let state = PrivacyRecord.State.restrict(expected.sdkChoice, by: ceiling)
            if state != expected.state { beforePublish() }
            return observeRecord(expected, ceiling: ceiling, fence: fence)
        } ?? nil
    }

    func revoke() -> PrivacyRecord? {
        let record = PrivacyRecord(generation: UUID().uuidString.lowercased(), state: .denied)
        setMemoryFence(record)
        return completeRevocation(expected: record)
    }

    /// A queued older refusal must not overwrite a newer explicit grant or delete its scope.
    func completeRevocation(expected: PrivacyRecord) -> PrivacyRecord? {
        locked {
            guard memoryFence() == expected else { return nil }
            let result = writeRecord(expected, clearing: expected)
            if result == expected || memoryFence() == expected {
                try? FileManager.default.removeItem(at: root.appendingPathComponent("scopes"))
                _ = OwnerChoices(root: root).clear()
            }
            return result
        } ?? nil
    }

    func scope(owner: String, record: PrivacyRecord) -> URL? {
        guard owner.count == 64, owner.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), record.valid else { return nil }
        return root.appendingPathComponent("scopes", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(record.generation, isDirectory: true)
    }

    func authorized<T>(record: PrivacyRecord, _ action: () -> T) -> T? {
        guard memoryFence() == nil else { return nil }
        return locked {
            guard record.state == .granted, readRecord() == record else { return nil }
            let value = action()
            guard memoryFence() == nil, readRecord() == record else { return nil }
            return value
        } ?? nil
    }

    private enum Read { case missing, invalid, valid(PrivacyRecord) }

    private func readStatus() -> Read {
        if let fence = memoryFence() { return .valid(fence) }
        let url = root.appendingPathComponent("privacy.json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .invalid }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 257)
        let size = Darwin.read(fd, &bytes, bytes.count)
        guard size > 0, size <= 256,
              let record = try? decoder.decode(PrivacyRecord.self, from: Data(bytes.prefix(size))), record.valid else { return .invalid }
        return .valid(record)
    }

    private func readRecord() -> PrivacyRecord? {
        if case .valid(let record) = readStatus() { return record }
        return nil
    }

    private func observeRecord(_ record: PrivacyRecord, ceiling: PrivacyRecord.State, fence: PrivacyRecord?) -> PrivacyRecord? {
        let state = PrivacyRecord.State.restrict(record.sdkChoice, by: ceiling)
        if state == record.state { return record }
        let fresh = PrivacyRecord(generation: UUID().uuidString.lowercased(), state: state, sdkChoice: record.sdkChoice)
        return publishRecord(fresh, fence: fence, wipe: true)
    }

    private func publish(choice: PrivacyRecord.State, ceiling: PrivacyRecord.State, fence: PrivacyRecord?) -> PrivacyRecord? {
        let record = PrivacyRecord(generation: UUID().uuidString.lowercased(), state: .restrict(choice, by: ceiling), sdkChoice: choice)
        let result = publishRecord(record, fence: fence, wipe: choice != .granted)
        if choice != .granted { _ = OwnerChoices(root: root).clear() }
        return result
    }

    private func publishRecord(_ record: PrivacyRecord, fence: PrivacyRecord?, wipe: Bool) -> PrivacyRecord? {
        if record.state != .granted && !replaceMemoryFence(expected: fence, with: record) { return nil }
        defer { if wipe { try? FileManager.default.removeItem(at: root.appendingPathComponent("scopes")) } }
        return writeRecord(record, clearing: record.state == .granted ? fence : record)
    }

    private func writeRecord(_ record: PrivacyRecord, clearing expectedFence: PrivacyRecord? = nil) -> PrivacyRecord? {
        do {
            let url = root.appendingPathComponent("privacy.json")
            try encoder.encode(record).write(to: url, options: .atomic)
            try protect(url, directory: false)
            clearMemoryFence(expected: expectedFence)
            return memoryFence() == nil ? record : nil
        } catch { return nil }
    }

    private func locked<T>(_ action: () -> T) -> T? {
        mutex.lock()
        defer { mutex.unlock() }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try protect(root, directory: true)
        } catch { return nil }
        let fd = open(root.appendingPathComponent("privacy.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return action()
    }

    private func protect(_ url: URL, directory: Bool) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: directory ? 0o700 : 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
}
