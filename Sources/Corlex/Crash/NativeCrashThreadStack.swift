import CCorlexCrash
import Foundation

/// Preparing the main stack captures no data and never installs or arms a crash handler.
/// Do not wait on main while holding a client, privacy or reporter mutex.
enum NativeCrashThreadStack {
    static func prepare() {
        if Thread.isMainThread {
            _ = corlex_crash_prepare_thread_stack()
        } else {
            DispatchQueue.main.async { _ = corlex_crash_prepare_thread_stack() }
        }
    }
}
