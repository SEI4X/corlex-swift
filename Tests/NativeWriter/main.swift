import Foundation

let mode = CommandLine.arguments[1]
let root = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-writer-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
let ledger = PrivacyLedger(root: root)
let granted = ledger.prepare(requested: .granted)!
let first = StorageScope(ledger: ledger, owner: String(repeating: "a", count: 64), record: granted)
var scope = first
let device = DeviceInfo(appVersion: String(repeating: "x", count: 124) + "😀", build: String(repeating: "b", count: 33), osVersion: "18.3", deviceModel: "iPhone16,2", locale: "en-US")
let reporter = CrashReporter.shared
assert(reporter.install(storage: Storage.bound(scope: scope)!, device: device, captureErrorMessages: mode == "detailed"))
if mode == "lock-order" {
    let entered = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    _ = ledger.authorized(record: granted) {
        DispatchQueue.global().async {
            let exception = NSException(name: .rangeException, reason: "synthetic", userInfo: nil)
            entered.signal()
            reporter.write(exception)
            finished.signal()
        }
        assert(entered.wait(timeout: .now() + 3) == .success)
        Thread.sleep(forTimeInterval: 0.05)
        reporter.disable(deleteReports: false) // native ceiling callback under state admission
    }
    assert(finished.wait(timeout: .now() + 3) == .success)
    assert(reporter.takePending(storage: Storage.bound(scope: first)!).isEmpty)
    print("Native state-to-reporter lock order passed")
    try FileManager.default.removeItem(at: root)
    exit(0)
}
if mode == "rearm" {
    reporter.disable(deleteReports: false)
    let denied = ledger.revoke()!
    let fresh = ledger.grant(expected: denied)!
    scope = StorageScope(ledger: ledger, owner: String(repeating: "b", count: 64), record: fresh)
    assert(reporter.install(storage: Storage.bound(scope: scope)!, device: device))
}
let privateMessage = "person@example.test https://user:secret@example.test/private?token=secret"
reporter.write(NSException(name: .init("User person@example.test"), reason: privateMessage, userInfo: nil))
let storage = Storage.bound(scope: scope)!
let directory = storage.directory.appendingPathComponent(CrashReporter.folderName)
let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
assert(files.count == 1)
let raw = try Data(contentsOf: files[0])
let firstLine = raw.split(separator: 10).first!
let header = try JSONSerialization.jsonObject(with: Data(firstLine)) as! [String: Any]
assert(header["name"] as? String == "NativeError")
assert(header["owner"] as? String == scope.owner)
assert(header["generation"] as? String == scope.record.generation)
assert(header["app_version"] as? String == device.appVersion)
assert(header["build"] as? String == "") // oversized original build is unknown, never a prefix
let expected = mode == "detailed" ? privateMessage : NativeCrashPrivacy.omitted
assert(header["message"] as? String == expected)
if mode != "detailed" { assert(!String(decoding: raw, as: UTF8.self).contains("person@example.test")) }
let attributes = try FileManager.default.attributesOfItem(atPath: files[0].path)
assert((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
var wrong = header
wrong["owner"] = String(repeating: "c", count: 64)
try JSONSerialization.data(withJSONObject: wrong).write(to: directory.appendingPathComponent("crash-foreign.corlex"))
try Data(repeating: 32, count: 512 * 1024 + 1).write(to: directory.appendingPathComponent("crash-oversized.corlex"))
let parsed = reporter.takePending(storage: storage, captureErrorMessages: mode == "detailed")
assert(parsed.count == 1 && parsed[0].properties["message"] == .string(expected))
let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
assert(remaining.isEmpty)
reporter.disable(deleteReports: false)
assert(!reporter.install(storage: storage, device: device)) // admitted fatal writer remains pinned
print("Native writer scope, privacy, exact metadata and terminal admission passed: \(mode)")
