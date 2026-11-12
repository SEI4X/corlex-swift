import UIKit
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

/// Observes the app's lifecycle notifications. All callbacks run on the main queue.
final class Lifecycle {
    struct Handlers {
        var didEnterBackground: () -> Void
        var willEnterForeground: () -> Void
        var didBecomeActive: () -> Void
    }

    private var tokens: [NSObjectProtocol] = []

    init(handlers: Handlers, center: NotificationCenter = .default) {
        let add = { (name: Notification.Name, action: @escaping () -> Void) in
            self.tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in action() })
        }
        add(UIApplication.didEnterBackgroundNotification, handlers.didEnterBackground)
        add(UIApplication.willEnterForegroundNotification, handlers.willEnterForeground)
        add(UIApplication.didBecomeActiveNotification, handlers.didBecomeActive)
    }

    func stop(center: NotificationCenter = .default) {
        tokens.forEach { center.removeObserver($0) }
        tokens = []
    }

    deinit { stop() }
}

/// Keeps the process alive for a few more seconds so the last flush can finish after the app
/// went to the background (`beginBackgroundTask`). Must be called on the main thread.
enum BackgroundTask {
    static func run(_ work: (_ finish: @escaping () -> Void) -> Void) {
        var identifier = UIBackgroundTaskIdentifier.invalid
        let finish = {
            DispatchQueue.main.async {
                if identifier != .invalid {
                    UIApplication.shared.endBackgroundTask(identifier)
                    identifier = .invalid
                }
            }
        }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "ru.corlex.flush", expirationHandler: finish)
        if identifier == .invalid { return work {} }
        work(finish)
    }
}

/// `consent: .att`: the status App Tracking Transparency reports, mapped to a consent state.
/// Reading the status needs no permission. The SDK never shows the prompt and never touches the
/// advertising identifier.
enum TrackingStatus {
    static func consent() -> CorlexConsent {
        #if canImport(AppTrackingTransparency)
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .pending
        @unknown default: return .pending
        }
        #else
        return .granted
        #endif
    }
}
