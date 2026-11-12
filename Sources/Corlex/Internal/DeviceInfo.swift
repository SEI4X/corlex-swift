import Foundation

/// What describes this device and build. Read once at start. No advertising id, no vendor id,
/// no device name: only the model identifier, the OS version and the app's own version.
struct DeviceInfo: Equatable {
    var appVersion: String?
    var build: String?
    var osVersion: String
    var deviceModel: String
    var locale: String

    static func current(bundle: Bundle = .main) -> DeviceInfo {
        let info = bundle.infoDictionary
        return DeviceInfo(
            appVersion: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            osVersion: osVersionString(),
            deviceModel: modelIdentifier(),
            locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        )
    }

    var context: WireContext {
        var context = WireContext()
        context.appVersion = appVersion?.truncated(toUTF8Bytes: Limits.maxContext)
        context.osVersion = osVersion
        context.deviceModel = deviceModel
        context.locale = locale.truncated(toUTF8Bytes: Limits.maxContext)
        return context
    }

    /// `18.3` or `18.3.1`.
    static func osVersionString(_ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    /// `iPhone16,2`. In the simulator the model it pretends to be.
    static func modelIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return model }
        #endif
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
