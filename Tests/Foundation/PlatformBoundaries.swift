import Foundation

// The exact client/storage/network/config sources run with installGlobalHooks=false.
// UIKit/crash boundaries must never be entered by this Foundation-only suite; iOS CI and
// the separate native writer/symbol fixtures exercise those real platform implementations.
final class Lifecycle {
    struct Handlers {
        var didEnterBackground: () -> Void
        var willEnterForeground: () -> Void
        var didBecomeActive: () -> Void
    }
    init(handlers: Handlers) { fatalError("Foundation suite entered UIKit lifecycle") }
}
enum BackgroundTask {
    static func run(_ work: (_ finish: @escaping () -> Void) -> Void) { fatalError("Foundation suite entered UIKit background task") }
}
enum ScreenTracker {
    static func start(handler: @escaping (String) -> Void) { fatalError("Foundation suite entered UIKit screen capture") }
    static func stop() { fatalError("Foundation suite entered UIKit screen capture") }
}
enum TrackingStatus {
    static func consent() -> CorlexConsent { fatalError("Foundation suite used live ATT instead of injected status") }
}
final class CrashReporter {
    static let shared = CrashReporter()
    func install(storage: Storage, device: DeviceInfo, captureErrorMessages: Bool = false) { fatalError("Foundation suite entered native crash capture") }
    func disable(deleteReports: Bool) { fatalError("Foundation suite entered native crash capture") }
    func takePending(storage: Storage, captureErrorMessages: Bool = false) -> [CapturedCrash] { fatalError("Foundation suite entered native crash recovery") }
}
