import Foundation

/// Where the SDK stands on consent (docs: services/ingest/docs/protocol.md §4.1).
public enum CorlexConsent: String {
    /// Events are collected and sent.
    case granted
    /// Nothing is sent and nothing is written to disk; events wait in memory until `optIn()`.
    case pending
    /// The person said no (or App Tracking Transparency did): nothing is collected.
    case denied
}

/// The consent the app starts the SDK with.
public enum CorlexStartConsent {
    /// The app collects consent itself (or needs none). The default.
    case granted
    /// Start silent until `Corlex.optIn()`.
    case pending
    /// Follow App Tracking Transparency: `notDetermined` is `pending`, `authorized` is `granted`,
    /// `denied` and `restricted` are `denied`. The SDK only reads the status; it never shows the
    /// prompt (the app decides when to ask) and never reads the advertising identifier.
    case att
}

/// Which automatic events the SDK sends. Each part can be switched off.
public struct CorlexAutocapture {
    /// `app_open`, once per launch.
    public var appOpen = true
    /// `app_background` and `app_foreground`.
    public var lifecycle = true
    /// `screen_view` for UIKit view controllers of the app (a one-time swizzle of
    /// `viewDidAppear(_:)`). SwiftUI screens use `.corlexScreen("Name")` whatever this says.
    public var uiKitScreens = true
    /// Native crashes (`NSException` and fatal signals) as `corlex.crash` on the next launch.
    public var crashes = true

    public init() {}

    /// Everything off: the app calls `track`, `screen` and `identify` itself.
    public static var none: CorlexAutocapture {
        var value = CorlexAutocapture()
        value.appOpen = false
        value.lifecycle = false
        value.uiKitScreens = false
        value.crashes = false
        return value
    }
}

/// Remote Config behaviour; like everything that touches the network it needs consent.
public struct CorlexConfigOptions {
    /// Apply a downloaded config at once. Default `false`: it takes effect at the next launch.
    public var live = false
    /// How long `Corlex.config.ready()` waits for the download. Default 1.5 seconds.
    public var timeout: TimeInterval = 1.5
    /// `false` never downloads a config.
    public var enabled = true

    public init() {}
}

public struct CorlexOptions {
    /// Ingest base URL. Default `https://ingest.corlex.ru`.
    public var endpoint = URL(string: "https://ingest.corlex.ru")!
    /// Remote Config base URL (edge-config). Default `https://config.corlex.ru`.
    public var configEndpoint = URL(string: "https://config.corlex.ru")!
    public var consent: CorlexStartConsent = .granted
    public var autocapture = CorlexAutocapture()
    public var config = CorlexConfigOptions()
    /// Events per request, 1...500. Default 20.
    public var batchSize = 20
    /// Seconds before a partial batch is sent. Default 5.
    public var flushInterval: TimeInterval = 5
    /// Log what the SDK drops or retries to the console.
    public var debug = false
    /// Detailed automatic exception messages may contain user data; default is generic.
    public var captureErrorMessages = false
    /// Explicit HTTP development override. Prefer a condition from the host application's build.
    public var allowInsecureHttp = false

    public init() {}
}
