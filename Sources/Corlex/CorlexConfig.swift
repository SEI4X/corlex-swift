import Foundation

/// A type a Remote Config parameter can be read as.
public protocol CorlexConfigValue {
    /// The value if `json` (Bool, number, String, array or dictionary) is of this type.
    static func corlexValue(from json: Any) -> Self?
}

extension Bool: CorlexConfigValue {
    public static func corlexValue(from json: Any) -> Bool? { json as? Bool }
}

extension String: CorlexConfigValue {
    public static func corlexValue(from json: Any) -> String? { json as? String }
}

extension Int: CorlexConfigValue {
    public static func corlexValue(from json: Any) -> Int? {
        if let int = json as? Int, !(json is Bool) { return int }
        if let double = json as? Double, double == double.rounded(), abs(double) < 1e15 { return Int(double) }
        return nil
    }
}

extension Double: CorlexConfigValue {
    public static func corlexValue(from json: Any) -> Double? {
        if json is Bool { return nil }
        if let double = json as? Double { return double }
        return (json as? Int).map(Double.init)
    }
}

extension Array: CorlexConfigValue where Element == Any {
    public static func corlexValue(from json: Any) -> [Any]? { json as? [Any] }
}

extension Dictionary: CorlexConfigValue where Key == String, Value == Any {
    public static func corlexValue(from json: Any) -> [String: Any]? { json as? [String: Any] }
}

/// Handle for ``CorlexConfig/onUpdate(_:)``.
public final class CorlexConfigSubscription {
    private let cancelAction: () -> Void

    init(cancel: @escaping () -> Void) { cancelAction = cancel }

    /// Stops listening.
    public func cancel() { cancelAction() }

    deinit { cancelAction() }
}

/// Remote Config: parameters set in the Corlex screen and published, evaluated on the device.
/// A new publication applies at the next launch (a value never changes in the middle of a
/// session) unless the app awaited ``ready()`` before its first read or set `config.live`.
public struct CorlexConfig {
    init() {}

    /// The value of a parameter for this person, or `default` (see ``Corlex/flag(_:default:)``).
    public func get<T: CorlexConfigValue>(_ key: String, default fallback: T) -> T {
        guard let client = Corlex.client, let seed = JSONValue(any: fallback) else { return fallback }
        let json = client.configValue(key, fallback: seed)
        return T.corlexValue(from: json.any) ?? fallback
    }

    /// Every parameter that applies to this person, by key.
    public func getAll() -> [String: Any] {
        Corlex.client?.configValues().mapValues(\.any) ?? [:]
    }

    /// Returns when this launch's download finished or after `config.timeout`, whichever is
    /// first. Await it before the first read to see a config published since the last launch.
    public func ready() async {
        guard let client = Corlex.client else { return }
        await withCheckedContinuation { continuation in
            client.configReady { continuation.resume() }
        }
    }

    /// Downloads now (one request, shared by concurrent calls).
    public func refresh() async {
        guard let client = Corlex.client else { return }
        await withCheckedContinuation { continuation in
            client.refreshConfig { continuation.resume() }
        }
    }

    /// Called on the main queue when a newer config was downloaded. Keep the result alive.
    public func onUpdate(_ listener: @escaping (CorlexConfigUpdate) -> Void) -> CorlexConfigSubscription {
        guard let client = Corlex.client else { return CorlexConfigSubscription {} }
        let id = client.onConfigUpdate(listener)
        return CorlexConfigSubscription { client.removeConfigListener(id) }
    }
}
