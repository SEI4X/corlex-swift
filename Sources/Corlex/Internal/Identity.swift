import Foundation

/// Who is acting. The anonymous id is a random UUID the SDK makes itself: never the advertising
/// id and never the vendor id. `userId` appears after `identify`. Until `persist()` is called
/// (consent pending) nothing is written.
struct Identity {
    private static let anonymousFile = "anonymous_id"
    private static let userFile = "user_id"

    private(set) var anonymousId: String
    private(set) var userId: String?
    private var shouldPersist: Bool
    private let storage: Storage?

    init(storage: Storage?, persisted: Bool) {
        self.storage = storage
        self.shouldPersist = persisted
        let saved = persisted ? storage?.readText(Self.anonymousFile) : nil
        self.anonymousId = saved.flatMap { $0.isEmpty ? nil : $0 } ?? Self.newAnonymousId()
        self.userId = persisted ? storage?.readText(Self.userFile).flatMap { $0.isEmpty ? nil : $0 } : nil
        if persisted { persist() }
    }

    static func newAnonymousId() -> String { "a_\(UUID().uuidString.lowercased())" }

    /// The id the rollout buckets on: the user after `identify`, otherwise the anonymous one.
    var bucketId: String { userId ?? anonymousId }

    mutating func persist() {
        shouldPersist = true
        storage?.writeText(anonymousId, to: Self.anonymousFile)
        if let userId { storage?.writeText(userId, to: Self.userFile) }
    }

    mutating func setUser(_ id: String) {
        let trimmed = id.truncated(toUTF8Bytes: Limits.maxID)
        userId = trimmed
        if shouldPersist { storage?.writeText(trimmed, to: Self.userFile) }
    }

    /// Logout: forget the user and start a new anonymous person.
    mutating func reset() {
        userId = nil
        anonymousId = Self.newAnonymousId()
        storage?.remove(Self.userFile)
        if shouldPersist { persist() }
    }

    /// Opt-out: remove every trace from storage and stop persisting.
    mutating func wipe() {
        storage?.remove(Self.anonymousFile)
        storage?.remove(Self.userFile)
        shouldPersist = false
        userId = nil
        anonymousId = Self.newAnonymousId()
    }
}
