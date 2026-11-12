import CCorlexCrash
import Foundation

/// Native crash capture: an `NSException` handler and, in C, fatal-signal handlers. Each writes
/// one file in `Application Support/Corlex/crashes` (a JSON header line, then one line per
/// stack frame; see `CrashReportReader`). The file is sent as `corlex.crash` by the next launch,
/// with its original timestamp. Both handlers chain to whatever was installed before (Crashlytics,
/// Sentry, Firebase), so installing Corlex next to another reporter changes nothing for it.
///
/// Mach exceptions are not handled: the signals above cover what an app can recover from, and a
/// second handler type would race other reporters for the same crash.
final class CrashReporter {
    static let shared = CrashReporter()
    static let folderName = "crashes"
    static let filePrefix = "crash-"
    static let fileSuffix = ".corlex"

    private let lock = NSLock()
    private var installed = false
    private var enabled = false
    private var captureErrorMessages = false
    private var captureEpoch: UInt64 = 0
    private var previousExceptionHandler: NSUncaughtExceptionHandler?
    private var folder: Storage?

    /// Installs the handlers once per process; calling again only re-enables them.
    @discardableResult
    func install(storage: Storage, device: DeviceInfo, captureErrorMessages: Bool = false) -> Bool {
        guard let directory = storage.prepare(subfolder: Self.folderName) else { return false }
        let crashId = UUID().uuidString.lowercased()
        let path = directory.appendingPathComponent("\(Self.filePrefix)\(crashId)\(Self.fileSuffix)").path
        guard let prefix = Self.headerPrefix(crashId: crashId, device: device, scope: storage.scope),
              prefix.utf8.count < 1024, path.utf8.count < 1024 else { return false }
        // Match native state admission → Reporter.lock; never query state while holding the reporter.
        return storage.authorized {
            lock.lock()
            defer { lock.unlock() }
            corlex_crash_set_enabled(0)
            guard corlex_crash_install(path, prefix) == 1 else { return false }
            if !installed {
                previousExceptionHandler = NSGetUncaughtExceptionHandler()
                NSSetUncaughtExceptionHandler { exception in
                    CrashReporter.shared.write(exception)
                    CrashReporter.shared.previousExceptionHandler?(exception)
                }
            }
            self.captureErrorMessages = captureErrorMessages
            folder = Storage(directory: directory, scope: storage.scope)
            installed = true
            enabled = true
            captureEpoch &+= 1
            return true
        } ?? false
    }

    /// Opt-out: the handlers pass everything on and unsent reports are deleted.
    func disable(deleteReports: Bool) {
        lock.lock()
        enabled = false
        captureEpoch &+= 1
        corlex_crash_set_enabled(0)
        let old = folder
        lock.unlock()
        if deleteReports { old?.wipe() }
    }

    /// The reports of earlier launches, oldest first. The files are deleted as they are read:
    /// the caller must queue the events straight away.
    func takePending(storage: Storage, captureErrorMessages: Bool = false) -> [CapturedCrash] {
        let directory = storage.directory.appendingPathComponent(Self.folderName, isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let reports = Storage(directory: directory, scope: storage.scope)
        var crashes: [CapturedCrash] = []
        for url in urls where url.lastPathComponent.hasPrefix(Self.filePrefix) && url.pathExtension == "corlex" {
            let name = url.lastPathComponent
            defer { reports.remove(name) }
            if let data = reports.read(name, limit: 512 * 1024), NativeCrashPrivacy.matches(data, scope: storage.scope),
               let crash = CrashReportReader.parse(data, captureErrorMessages: captureErrorMessages) {
                crashes.append(crash)
                crashes.sort { $0.timestamp < $1.timestamp }
                if crashes.count > Limits.maxPendingCrashes { crashes.removeFirst() }
            }
        }
        return Array(crashes.suffix(Limits.maxPendingCrashes))
    }

    // MARK: - NSException

    func write(_ exception: NSException) {
        lock.lock()
        let isEnabled = enabled
        let detailed = captureErrorMessages
        let snapshot = folder
        let epoch = captureEpoch
        lock.unlock()
        guard isEnabled, let snapshot else { return }
        var fd: Int32 = -1
        let admitted = snapshot.authorized { () -> Bool in
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.enabled, self.captureEpoch == epoch else { return false }
            fd = corlex_crash_open_report()
            return fd >= 0
        }
        guard admitted == true, fd >= 0 else {
            if fd >= 0 { close(fd) }
            return
        }
        defer { close(fd) }
        let reason = NativeCrashPrivacy.message(exception.reason, detailed: detailed)
        corlex_crash_write_header(fd, "ns_exception", Self.escaped(NativeCrashPrivacy.name(exception.name.rawValue)), Self.escaped(reason))
        let addresses = exception.callStackReturnAddresses.map { $0.uintValue }
        addresses.withUnsafeBufferPointer { buffer in
            corlex_crash_write_frames(fd, buffer.baseAddress, Int32(min(buffer.count, Limits.maxCrashFrames)), 1)
        }
    }

    /// A string as JSON string content (no surrounding quotes).
    static func escaped(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return String(json.dropFirst().dropLast())
    }

    /// The start of the header line, shared by both handlers; ends with a comma.
    static func headerPrefix(crashId: String, device: DeviceInfo, scope: StorageScope? = nil) -> String? {
        // Short values only: the C side keeps the prefix in a fixed buffer.
        let short = { (text: String) in text.truncated(toUTF8Bytes: 64) }
        var header: [String: Any] = [
            "v": 1, "crash_id": crashId, "kind": "native", "fatal": true,
            "arch": DeviceInfo.architecture, "os_version": short(device.osVersion),
            "device_model": short(device.deviceModel),
        ]
        header["app_version"] = NativeCrashPrivacy.metadata(device.appVersion, limit: 128)
        header["build"] = NativeCrashPrivacy.metadata(device.build, limit: 32)
        if let scope {
            header["owner"] = scope.owner
            header["generation"] = scope.record.generation
        }
        guard let data = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8), text.hasSuffix("}") else { return nil }
        return String(text.dropLast()) + ","
    }
}
