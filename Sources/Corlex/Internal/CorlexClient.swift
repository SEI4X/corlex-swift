import Foundation

/// One SDK instance: events, consent, the queue, delivery, identity and Remote Config. Every
/// piece of state belongs to `queue`, a serial queue; the public API either hops onto it or
/// (for the calls that return a value) waits on it. Mirrors `sdk-core/src/client.ts`.
final class CorlexClient {
    static let consentFile = "consent"

    let queue = DispatchQueue(label: "ru.corlex.sdk", qos: .utility)
    let key: String
    let options: CorlexOptions
    let env: ClientEnvironment
    var storage: Storage?
    let binding: ClientBinding
    var consent: CorlexConsent
    var runtime: Runtime?
    var lifecycle: Lifecycle?
    var observing = false
    var lastScreen: String?
    var hasBeenInBackground = false
    var exposed = Set<String>()
    private var warnedName = false
    private var openedActivation: UUID?

    init?(key: String, options: CorlexOptions, env: ClientEnvironment) {
        guard let owner = StorageBinding.digest(key: key, endpoint: options.endpoint, configEndpoint: options.configEndpoint,
                                                allowInsecureHttp: options.allowInsecureHttp) else { return nil }
        self.key = key
        self.options = options
        let requested = Self.requestedConsent(options: options, env: env)
        let binding = ClientBinding(.init(owner: owner, legacy: env.storage, requested: requested,
            ceilingOf: { options.consent == .att ? PrivacyRecord.State(rawValue: env.trackingStatus().rawValue) ?? .pending : .granted }))
        self.binding = binding
        var environment = env
        environment.storage = binding.storage
        environment.transport = BoundTransport(base: env.transport, binding: binding)
        self.env = environment
        self.storage = binding.storage
        self.consent = CorlexConsent(rawValue: binding.state.rawValue) ?? .pending
        // Handlers go in before anything else can crash, and on the caller's thread (the main
        // thread in an app): the signal handler's alternate stack belongs to the thread that sets it.
        if consent == .granted, binding.canSend { installCrashHandlers() }
        queue.async { self.boot() }
    }

    private static func requestedConsent(options: CorlexOptions, env: ClientEnvironment) -> PrivacyRecord.State {
        switch options.consent {
        case .granted: return .granted
        case .pending: return .pending
        case .att: return .granted
        }
    }

    func stop() {
        if env.installGlobalHooks { CrashReporter.shared.disable(deleteReports: false) }
        binding.invalidate()
        env.transport.pause()
        queue.async {
            self.runtime?.sender.stop()
            self.runtime?.remote.stop(wipe: false)
            self.lifecycle = nil
        }
    }

    // MARK: - Start

    private func boot() {
        observeTracking()
        guard binding.isCurrent else { return }
        if env.installGlobalHooks { observeApp() }
        if consent != .denied, runtime == nil { makeRuntime() }
        guard let runtime else { return }
        if consent == .granted {
            processPendingCrashes()
            startRemoteConfig()
        }
        captureAppOpen()
        runtime.sender.schedule()
    }

    func captureAppOpen() {
        guard options.autocapture.appOpen, runtime != nil, openedActivation != binding.token else { return }
        openedActivation = binding.token
        capture(EventName.appOpen, [:], CaptureMeta())
    }

    func makeRuntime() {
        let granted = consent == .granted
        let eventQueue = EventQueue(storage: storage, persisted: granted)
        var config = Sender.Config(endpoint: options.endpoint, key: key)
        config.batchSize = max(1, min(options.batchSize, Limits.maxBatchEvents))
        config.flushInterval = options.flushInterval
        config.backoff = env.backoff
        config.allowed = { [binding] in binding.canSend }
        let sender = Sender(queue: eventQueue, transport: env.transport, config: config, dispatch: queue) {
            [debug = options.debug] message in
            if debug { print("[corlex] \(message)") }
        }
        runtime = Runtime(
            queue: eventQueue,
            sender: sender,
            remote: makeRemoteConfig(),
            identity: Identity(storage: storage, persisted: granted)
        )
        if !granted { sender.stop() }
    }

    func installCrashHandlers() {
        guard options.autocapture.crashes, env.installGlobalHooks, binding.canSend, let storage else { return }
        CrashReporter.shared.install(storage: storage, device: env.device, captureErrorMessages: options.captureErrorMessages)
    }

    func processPendingCrashes() {
        guard options.autocapture.crashes, let storage else { return }
        for crash in CrashReporter.shared.takePending(storage: storage, captureErrorMessages: options.captureErrorMessages) {
            let meta = CaptureMeta(
                timestamp: crash.timestamp, eventId: crash.crashId,
                appVersion: crash.appVersion, osVersion: crash.osVersion, build: crash.build
            )
            capture(EventName.crash, crash.properties, meta)
        }
    }

    // MARK: - Events

    /// Queues an event. Safe before consent: it waits in memory. Runs on `queue`.
    func capture(_ name: String, _ properties: [String: JSONValue], _ meta: CaptureMeta) {
        observeTracking()
        guard let runtime, consent != .denied, binding.isCurrent else { return }
        guard EventName.isValid(name) else { return rejectName() }
        let event = buildEvent(runtime, name: name, properties: properties, meta: meta)
        if runtime.queue.contains(event.eventId) { return }
        if !runtime.queue.push(event) {
            log("event_too_large")
            return
        }
        if consent == .granted { runtime.sender.schedule() }
    }

    private func buildEvent(_ runtime: Runtime, name: String, properties: [String: JSONValue], meta: CaptureMeta) -> WireEvent {
        var context = env.device.context
        if let version = meta.appVersion { context.appVersion = version.truncated(toUTF8Bytes: Limits.maxContext) }
        if let version = meta.osVersion { context.osVersion = version }
        var properties = properties
        // The release key of every event; the SDK's value wins over one the app passed, because
        // symbolication and release health read it.
        if let build = meta.build ?? env.device.build {
            if properties.count >= Limits.maxProperties, properties["build"] == nil,
               let last = properties.keys.sorted().last {
                properties[last] = nil
            }
            properties["build"] = .string(build.truncated(toUTF8Bytes: Limits.maxPropertyString))
        }
        return WireEvent(
            eventId: meta.eventId ?? UUID().uuidString.lowercased(),
            name: name,
            timestamp: Timestamp.string(from: meta.timestamp ?? env.now()),
            userId: runtime.identity.userId,
            anonymousId: runtime.identity.anonymousId,
            properties: properties,
            context: context
        )
    }

    private func rejectName() {
        guard !warnedName else { return }
        warnedName = true
        print("[corlex] invalid_event_name")
    }

    func log(_ message: String) {
        if options.debug { print("[corlex] \(message)") }
    }

    // MARK: - Public operations (called from any thread)

    func track(_ name: String, _ properties: [String: JSONValue] = [:]) {
        queue.async { self.capture(name, properties, CaptureMeta()) }
    }

    func screen(_ name: String, _ properties: [String: JSONValue], source: String) {
        queue.async { self.screenView(name, properties, source: source) }
    }

    func screenView(_ name: String, _ properties: [String: JSONValue], source: String) {
        var props = properties
        props["screen"] = .string(name.truncated(toUTF8Bytes: Limits.maxPropertyString))
        props["source"] = .string(source)
        if let previous = lastScreen { props["previous_screen"] = .string(previous) }
        lastScreen = name.truncated(toUTF8Bytes: Limits.maxPropertyString)
        capture(EventName.screenView, props, CaptureMeta())
    }

    func identify(_ userId: String, _ traits: [String: JSONValue]) {
        guard !userId.isEmpty else { return }
        queue.async {
            self.observeTracking()
            guard let runtime = self.runtime, self.consent != .denied, self.binding.isCurrent else { return }
            runtime.identity.setUser(userId)
            self.capture(EventName.identify, traits, CaptureMeta())
        }
    }

    func setUserProperties(_ properties: [String: JSONValue]) {
        track(EventName.userProps, properties)
    }

    func reset() {
        queue.async {
            self.exposed.removeAll()
            self.lastScreen = nil
            if self.binding.isCurrent { self.runtime?.identity.reset() }
        }
    }

    func flush(completion: @escaping () -> Void) {
        queue.async {
            self.observeTracking()
            guard let runtime = self.runtime, self.consent == .granted, self.binding.canSend else { return completion() }
            runtime.sender.flush(completion: completion)
        }
    }

    /// Where consent stands. Waits for the queue, so it reflects every call made before it.
    func currentConsent() -> CorlexConsent {
        queue.sync { observeTracking(); return binding.isCurrent ? consent : binding.state == .pending ? .pending : .denied }
    }
}
