import Foundation

/// What every event carries in `context` (the protocol keeps only a fixed set of fields).
struct WireContext: Codable, Equatable {
    var platform = "ios"
    var locale: String?
    var appVersion: String?
    var os: String? = "iOS"
    var osVersion: String?
    var deviceModel: String?
    var sdk = SDKInfo()

    struct SDKInfo: Codable, Equatable {
        var name = SDKVersion.name
        var version = SDKVersion.number
    }

    enum CodingKeys: String, CodingKey {
        case platform, locale, os, sdk
        case appVersion = "app_version"
        case osVersion = "os_version"
        case deviceModel = "device_model"
    }
}

/// An event as `POST /v1/batch` takes it (services/ingest/docs/protocol.md).
struct WireEvent: Codable, Equatable {
    var eventId: String
    var name: String
    var timestamp: String
    var userId: String?
    var anonymousId: String?
    var properties: [String: JSONValue]
    var context: WireContext

    enum CodingKeys: String, CodingKey {
        case name, timestamp, properties, context
        case eventId = "event_id"
        case userId = "user_id"
        case anonymousId = "anonymous_id"
    }
}

enum SDKVersion {
    static let name = "corlex-swift"
    /// Kept equal to the release; the example app and the README name the same number.
    static let number = "0.1.0"
}
