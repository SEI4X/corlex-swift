import Foundation

/// The Corlex SDK. Call `Corlex.start(key:)` once at launch; every other call before it is ignored.
///
///     Corlex.start(key: "ck_live_…")
///     Corlex.track("purchase", properties: ["plan": "pro", "amount": 12.5])
///     let days = Corlex.flag("free_trial_days", default: 7)
///
/// All methods are thread-safe and return at once; delivery happens in the background.
public enum Corlex {
    private static let lock = NSLock()
    private static var shared: CorlexClient?

    /// Remote Config (SPEC §10): values set in the Corlex screen, evaluated on the device.
    public static let config = CorlexConfig()

    static var client: CorlexClient? {
        lock.lock()
        defer { lock.unlock() }
        return shared
    }

    /// Starts the SDK. Does nothing when called a second time.
    ///
    /// - Parameters:
    ///   - key: the project key, `ck_live_…` or `ck_test_…`. It only writes events and reads
    ///     flags; it is sent in a header, never in a URL.
    ///   - options: see ``CorlexOptions``.
    public static func start(key: String, options: CorlexOptions = CorlexOptions()) {
        guard StorageBinding.validKey(key) else {
            print("[corlex] invalid_sdk_key")
            return
        }
        guard endpointsAllowed(options) else { print("[corlex] invalid_endpoint"); return }
        start(key: key, options: options, environment: .live())
    }

    static func start(key: String, options: CorlexOptions, environment: ClientEnvironment) {
        guard StorageBinding.validKey(key) else { print("[corlex] invalid_sdk_key"); return }
        guard endpointsAllowed(options) else { print("[corlex] invalid_endpoint"); return }
        if environment.installGlobalHooks && options.autocapture.crashes { NativeCrashThreadStack.prepare() }
        lock.lock()
        defer { lock.unlock() }
        if shared == nil { shared = CorlexClient(key: key, options: options, env: environment) }
    }

    private static func endpointsAllowed(_ options: CorlexOptions) -> Bool {
        EndpointPolicy.allowed(options.endpoint, allowInsecureHttp: options.allowInsecureHttp) &&
            EndpointPolicy.allowed(options.configEndpoint, allowInsecureHttp: options.allowInsecureHttp)
    }

    /// Forgets the instance (tests only).
    static func stopForTesting() {
        lock.lock()
        shared?.stop()
        shared = nil
        lock.unlock()
    }

    // MARK: - Events

    /// Records an event. `name` is 1...128 characters of `a-z 0-9 _ . : -`; names starting with
    /// `corlex.` are reserved. Properties: strings, numbers, booleans, dates, arrays and
    /// dictionaries of those (long strings are cut, the rest is dropped).
    public static func track(_ name: String, properties: [String: Any]? = nil) {
        client?.track(name, PropertySanitizer.sanitize(properties))
    }

    /// Records a `screen_view` by hand. Use a fixed name per screen, never one built from user data.
    public static func screen(_ name: String, properties: [String: Any]? = nil) {
        screen(name, properties: properties, source: "manual")
    }

    static func screen(_ name: String, properties: [String: Any]?, source: String) {
        client?.screen(name, PropertySanitizer.sanitize(properties), source: source)
    }

    /// Links the anonymous person to your own user id. Call after login.
    public static func identify(_ userId: String, traits: [String: Any]? = nil) {
        client?.identify(userId, PropertySanitizer.sanitize(traits))
    }

    /// Merges properties into the user's profile; the last write wins.
    public static func setUserProperties(_ properties: [String: Any]) {
        client?.setUserProperties(PropertySanitizer.sanitize(properties))
    }

    /// Logout: forgets the user id and starts a new anonymous person.
    public static func reset() {
        client?.reset()
    }

    /// Sends everything queued now. Returns when the queue is empty or delivery failed.
    public static func flush() async {
        guard let client else { return }
        await withCheckedContinuation { continuation in
            client.flush { continuation.resume() }
        }
    }

    // MARK: - Remote Config

    /// The value of a Remote Config parameter for this person, or `default` when the parameter
    /// does not exist, the rollout does not reach them, the type differs, or the config is not
    /// there yet (no consent, first launch before the download). Never throws.
    public static func flag<T: CorlexConfigValue>(_ key: String, default fallback: T) -> T {
        config.get(key, default: fallback)
    }

    /// The person's variant in a running A/B test, or nil when the test is not running, not
    /// downloaded yet, or there is no consent (then show the default). Reading it sends one
    /// `corlex.exposure` per person and test per session.
    public static func experiment(_ key: String) -> CorlexVariant? {
        guard let assigned = client?.experiment(key) else { return nil }
        return CorlexVariant(name: assigned.variant, value: assigned.value.any)
    }

    // MARK: - Consent

    /// Where consent stands. `pending` until the person chose (when started with `.pending`).
    public static var consent: CorlexConsent {
        client?.currentConsent() ?? .denied
    }

    /// The person agreed: stores the choice, starts sending what waited in memory.
    public static func optIn() {
        client?.optIn()
    }

    /// The person said no: stops sending, deletes the queue, the ids and the saved config. The
    /// choice survives restarts: the next launch starts silent.
    public static func optOut() {
        client?.optOut()
    }
}

/// The variant a person got in an A/B test.
public struct CorlexVariant {
    /// Variant key: `control`, `variant_b`...
    public let name: String
    /// The value set for the variant in the Corlex screen (Bool, number, String, array or dictionary).
    public let value: Any
}
