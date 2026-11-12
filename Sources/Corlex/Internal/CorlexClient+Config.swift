import Foundation

/// Remote Config and A/B tests of the client (docs/remote-config.md, docs/experiments.md).
extension CorlexClient {
    func makeRemoteConfig() -> RemoteConfig {
        let rc = RemoteConfig.Options(
            storage: storage,
            endpoint: options.configEndpoint,
            key: key,
            live: options.config.live,
            idOf: { [weak self] in self?.runtime?.identity.bucketId },
            expose: { [weak self] experiment, variant in self?.expose(experiment, variant) },
            log: { [weak self] message in self?.log(message) }
        )
        return RemoteConfig(options: rc, transport: env.transport, dispatch: queue)
    }

    /// Config is downloaded only with consent: the SDK makes no request without it (SPEC §12.1).
    func startRemoteConfig() {
        if options.config.enabled, consent == .granted, binding.canSend { runtime?.remote.start() }
    }

    /// One `corlex.exposure` per person and experiment per session. Runs on `queue`.
    private func expose(_ experiment: String, _ variant: String) {
        guard let id = runtime?.identity.bucketId, exposed.insert("\(experiment)\u{0}\(id)").inserted else { return }
        capture(
            EventName.exposure,
            ["experiment": .string(experiment), "variant": .string(variant)],
            CaptureMeta()
        )
    }

    func configValue(_ key: String, fallback: JSONValue) -> JSONValue {
        queue.sync { self.observeTracking(); return self.binding.canSend ? (self.runtime?.remote.get(key, fallback: fallback) ?? fallback) : fallback }
    }

    func configValues() -> [String: JSONValue] {
        queue.sync { self.observeTracking(); return self.binding.canSend ? (self.runtime?.remote.getAll() ?? [:]) : [:] }
    }

    func experiment(_ key: String) -> Assignment? {
        queue.sync { self.observeTracking(); return self.binding.canSend ? self.runtime?.remote.experiment(key) : nil }
    }

    func refreshConfig(completion: @escaping () -> Void) {
        queue.async {
            self.observeTracking()
            guard let remote = self.runtime?.remote, self.consent == .granted, self.binding.canSend else { return completion() }
            remote.refresh(completion: completion)
        }
    }

    func configReady(completion: @escaping () -> Void) {
        queue.async {
            self.observeTracking()
            guard let remote = self.runtime?.remote, self.consent == .granted, self.binding.canSend else { return completion() }
            remote.ready(timeout: self.options.config.timeout, completion: completion)
        }
    }

    func onConfigUpdate(_ listener: @escaping (CorlexConfigUpdate) -> Void) -> UUID {
        queue.sync {
            observeTracking()
            return runtime?.remote.addListener { [binding] update in DispatchQueue.main.async { if binding.canSend { listener(update) } } } ?? UUID()
        }
    }

    func removeConfigListener(_ id: UUID) {
        queue.async { self.runtime?.remote.removeListener(id) }
    }
}
