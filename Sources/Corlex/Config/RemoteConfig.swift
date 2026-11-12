import Foundation

/// A newer config was downloaded. `applied == false`: it is saved and takes effect at the next launch.
public struct CorlexConfigUpdate {
    public let version: Int
    public let applied: Bool
}

/// The project's published config on this device (SPEC §10, docs/remote-config.md). The document
/// is downloaded once per launch (a conditional GET, usually a 304), kept in a file, and evaluated
/// HERE with the same stable bucketing as the server and the other SDKs, so no request names a
/// person. A value must not flip while the app runs: a new document is applied at once only when
/// nothing was read yet in this launch (or `live` is on), otherwise it waits for the next launch.
/// Runs on the client's serial queue.
final class RemoteConfig {
    struct Options {
        var storage: Storage?
        var platform = "ios"
        var endpoint: URL
        var key: String
        var live = false
        var idOf: () -> String?
        var expose: (_ experiment: String, _ variant: String) -> Void
        var log: (String) -> Void
    }

    static let fileName = "config.json"

    private struct Saved: Codable {
        var etag: String
        var doc: ConfigDocument
    }

    private let options: Options
    private let transport: Transport
    private let dispatch: DispatchQueue
    private var active: ConfigDocument?
    private var etag: String?
    private var started = false
    /// A value was handed out: from now on a new document waits for the next launch.
    private var handedOut = false
    private var waiting: [() -> Void] = []
    private var inflight: Int?
    private var generation = 0
    private var listeners: [UUID: (CorlexConfigUpdate) -> Void] = [:]

    init(options: Options, transport: Transport, dispatch: DispatchQueue) {
        self.options = options
        self.transport = transport
        self.dispatch = dispatch
    }

    /// Reads the saved document and downloads the current one. Needs consent: the caller checks.
    func start() {
        guard !started else { return }
        started = true
        load()
        // After the current task, so an opt-out right after start() cancels the download.
        let token = generation
        dispatch.async { [weak self] in
            guard let self, self.started, self.generation == token else { return }
            self.refresh {}
        }
    }

    /// Stops downloads; `wipe` also forgets the saved document (opt-out).
    func stop(wipe: Bool) {
        started = false
        generation += 1
        inflight = nil
        finishWaiting()
        if wipe {
            options.storage?.remove(Self.fileName)
            active = nil
            etag = nil
        }
    }

    // MARK: - Reading values

    func get(_ key: String, fallback: JSONValue) -> JSONValue {
        handedOut = true
        guard let id = options.idOf() else { return fallback }
        if let linked = active?.experiments?.first(where: { $0.p == key }),
           let assigned = ConfigEvaluator.assign(linked, userId: id) {
            // A parameter under test gives the person their variant's value, and that is the exposure.
            guard assigned.value.kind == fallback.kind else { return fallback }
            options.expose(linked.k, assigned.variant)
            return assigned.value
        }
        guard let param = active?.params.first(where: { $0.k == key }),
              let value = ConfigEvaluator.resolve(param, userId: id, platform: options.platform)
        else { return fallback }
        return value.kind == fallback.kind ? value : fallback
    }

    func getAll() -> [String: JSONValue] {
        handedOut = true
        guard let active, let id = options.idOf() else { return [:] }
        var values = ConfigEvaluator.resolveAll(active, userId: id, platform: options.platform)
        // Variants of linked parameters are listed, but listing is not an exposure.
        for experiment in active.experiments ?? [] {
            if let parameter = experiment.p, let assigned = ConfigEvaluator.assign(experiment, userId: id) {
                values[parameter] = assigned.value
            }
        }
        return values
    }

    /// The variant of a running experiment, or nil. Reading it IS the exposure.
    func experiment(_ key: String) -> Assignment? {
        handedOut = true
        guard let experiment = active?.experiments?.first(where: { $0.k == key }),
              let id = options.idOf(),
              let assigned = ConfigEvaluator.assign(experiment, userId: id) else { return nil }
        options.expose(experiment.k, assigned.variant)
        return assigned
    }

    func addListener(_ listener: @escaping (CorlexConfigUpdate) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    // MARK: - Downloading

    /// Downloads now; concurrent calls share one request. `completion` runs when it is over.
    func refresh(completion: @escaping () -> Void) {
        guard started else { return completion() }
        waiting.append(completion)
        if inflight == generation { return }
        inflight = generation
        download()
    }

    /// Calls back when this launch's download finished, or after `timeout`: whichever is first.
    func ready(timeout: TimeInterval, completion: @escaping () -> Void) {
        guard started else { return completion() }
        var finished = false
        let finish = {
            if finished { return }
            finished = true
            completion()
        }
        dispatch.asyncAfter(deadline: .now() + timeout, execute: finish)
        refresh(completion: finish)
    }

    private func download() {
        let token = generation
        var request = URLRequest(url: options.endpoint.appendingPathComponent("v1/config/document"))
        request.setValue(options.key, forHTTPHeaderField: "X-Corlex-Key")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        transport.send(request) { [weak self] result in
            guard let self else { return }
            self.dispatch.async {
                guard token == self.generation, self.started, self.inflight == token else { return }
                self.received(result)
                self.inflight = nil
                self.finishWaiting()
            }
        }
    }

    private func received(_ result: TransportResult) {
        guard case .response(let status, _, let body) = result else {
            return options.log("config: could not download")
        }
        guard status == 200 else {
            if status != 304 { options.log("config: the server answered \(status)") }
            return
        }
        // Anything that is not a document is ignored rather than trusted.
        guard let doc = ConfigValidation.decode(body) else { return }
        etag = doc.etag
        save(doc)
        let apply = options.live || !handedOut || active == nil
        if apply { active = doc }
        options.log("config v\(doc.version) \(apply ? "applied" : "saved for the next launch")")
        let update = CorlexConfigUpdate(version: doc.version, applied: apply)
        listeners.values.forEach { $0(update) }
    }

    // MARK: - Disk

    private func load() {
        guard let data = options.storage?.read(Self.fileName, limit: ConfigValidation.maxCacheBytes),
              ConfigValidation.bounded(data, cache: true),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              ConfigValidation.valid(saved.doc), saved.etag == saved.doc.etag else {
            options.storage?.remove(Self.fileName)
            return
        }
        active = saved.doc
        etag = saved.etag
    }

    private func finishWaiting() {
        let done = waiting
        waiting = []
        done.forEach { $0() }
    }

    private func save(_ doc: ConfigDocument) {
        guard let data = try? JSONEncoder().encode(Saved(etag: doc.etag, doc: doc)),
              ConfigValidation.bounded(data, cache: true) else { return }
        options.storage?.write(data, to: Self.fileName)
    }
}
