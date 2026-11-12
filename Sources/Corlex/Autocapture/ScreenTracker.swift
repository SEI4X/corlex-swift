import ObjectiveC
import UIKit

/// A view controller can name its own screen for `screen_view` (instead of its class name).
public protocol CorlexScreenNaming {
    var corlexScreenName: String { get }
}

/// `screen_view` for UIKit: swaps `viewDidAppear(_:)` of `UIViewController` for a version that
/// reports and then calls the original. The swap happens once per process and cannot be undone,
/// so `isEnabled` decides whether it reports (it is false after `optOut()` and when the app
/// turned UIKit screens off). Only view controllers of the app's own bundle count: containers,
/// UIKit's and SwiftUI's own controllers are skipped, so a SwiftUI app names its screens with
/// `.corlexScreen("Name")` instead.
enum ScreenTracker {
    private static let lock = NSLock()
    private static var swizzled = false
    private static var handler: ((String) -> Void)?

    static func start(handler: @escaping (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        guard !swizzled else { return }
        let original = #selector(UIViewController.viewDidAppear(_:))
        let replacement = #selector(UIViewController.corlex_viewDidAppear(_:))
        guard let from = class_getInstanceMethod(UIViewController.self, original),
              let to = class_getInstanceMethod(UIViewController.self, replacement) else { return }
        method_exchangeImplementations(from, to)
        swizzled = true
    }

    static func stop() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
    }

    fileprivate static func appeared(_ controller: UIViewController) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        guard let handler, let name = screenName(of: controller) else { return }
        handler(name)
    }

    /// The name of an app screen, or nil for controllers that are not screens.
    static func screenName(of controller: UIViewController, appBundle: Bundle = .main) -> String? {
        if let named = controller as? CorlexScreenNaming { return named.corlexScreenName }
        if isContainer(controller) { return nil }
        let type = type(of: controller)
        // Controllers of UIKit and SwiftUI live in other bundles than the app's.
        guard Bundle(for: type) == appBundle else { return nil }
        let full = NSStringFromClass(type)
        return full.split(separator: ".").last.map(String.init) ?? full
    }

    private static func isContainer(_ controller: UIViewController) -> Bool {
        controller is UINavigationController || controller is UITabBarController
            || controller is UISplitViewController || controller is UIPageViewController
            || controller is UIAlertController
    }
}

extension UIViewController {
    /// After the swap this is the original `viewDidAppear(_:)`, so calling it runs the original.
    @objc fileprivate func corlex_viewDidAppear(_ animated: Bool) {
        corlex_viewDidAppear(animated)
        ScreenTracker.appeared(self)
    }
}
