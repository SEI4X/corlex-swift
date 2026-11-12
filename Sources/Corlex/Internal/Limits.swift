import Foundation

/// Mirrors services/ingest/internal/event/validate.go and docs/protocol.md (as `sdk-core/src/limits.ts`).
enum Limits {
    static let maxName = 128
    static let maxID = 256
    static let maxContext = 128
    static let maxProperties = 100
    static let maxPropertyKey = 128
    static let maxPropertyString = 1024
    static let maxArray = 100
    static let maxDepth = 4
    static let maxBatchEvents = 500
    static let maxEventBytes = 32768
    /// One request body stays under the server's 1 MiB limit with room to spare.
    static let maxBatchBytes = 900_000
    /// Oldest events go first when a person stays offline for long.
    static let maxQueueEvents = 1000
    static let maxQueueBytes = 4 * 1024 * 1024
    static let maxCrashMessage = 512
    static let maxCrashFrames = 100
    static let maxPendingCrashes = 20
}

/// Event names the SDK emits; see docs/protocol.md.
enum EventName {
    static let identify = "corlex.identify"
    static let userProps = "corlex.user_props"
    static let exposure = "corlex.exposure"
    static let crash = "corlex.crash"
    static let appOpen = "app_open"
    static let appBackground = "app_background"
    static let appForeground = "app_foreground"
    static let screenView = "screen_view"

    /// `^[a-z0-9_.:-]{1,128}$`
    static func isValid(_ name: String) -> Bool {
        let count = name.utf8.count
        guard count >= 1, count <= Limits.maxName else { return false }
        return name.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7a) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x5f || byte == 0x2e || byte == 0x3a || byte == 0x2d
        }
    }
}

extension String {
    /// Cuts the string to at most `max` UTF-8 bytes without splitting a character.
    func truncated(toUTF8Bytes max: Int) -> String {
        if utf8.count <= max { return self }
        var result = ""
        var used = 0
        for scalar in unicodeScalars {
            let size = String(scalar).utf8.count
            if used + size > max { break }
            result.unicodeScalars.append(scalar)
            used += size
        }
        return result
    }
}
