import Foundation

/// Everything the client takes from the outside world, so tests can replace it: the folder it
/// writes to, the network, the device, the clock and the switches for the global side effects
/// (crash handlers, the swizzle, lifecycle observers) that must not run inside a unit test.
struct ClientEnvironment {
    var storage: Storage?
    var transport: Transport
    var device: DeviceInfo
    var trackingStatus: () -> CorlexConsent
    var now: () -> Date
    var installGlobalHooks: Bool
    /// Tests shorten the backoff and flush intervals through the options; this is the backoff.
    var backoff: Backoff

    static func live() -> ClientEnvironment {
        ClientEnvironment(
            storage: Storage.standard(),
            transport: URLSessionTransport(),
            device: DeviceInfo.current(),
            trackingStatus: TrackingStatus.consent,
            now: Date.init,
            installGlobalHooks: true,
            backoff: Backoff()
        )
    }
}

/// What an event that happened earlier keeps when it is recorded late (a crash found on the
/// next launch): its time, its id and the version of the app that crashed.
struct CaptureMeta {
    var timestamp: Date?
    var eventId: String?
    var appVersion: String?
    var osVersion: String?
    var build: String?
}

/// The parts that exist while the SDK collects (consent is not `denied`).
final class Runtime {
    let queue: EventQueue
    let sender: Sender
    let remote: RemoteConfig
    var identity: Identity

    init(queue: EventQueue, sender: Sender, remote: RemoteConfig, identity: Identity) {
        self.queue = queue
        self.sender = sender
        self.remote = remote
        self.identity = identity
    }
}
