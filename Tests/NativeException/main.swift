import Foundation

// Fresh process, no raise()/uncaught exception and no user application.
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-exception-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
let storage = Storage(directory: directory)
let device = DeviceInfo(appVersion: "1.2.3", build: "42", osVersion: "18.3", deviceModel: "iPhone16,2", locale: "en-US")
let reporter = CrashReporter.shared
assert(reporter.install(storage: storage, device: device))
reporter.write(NSException(name: .rangeException, reason: "synthetic exception", userInfo: nil))
let first = reporter.takePending(storage: storage)
assert(first.count == 1)
assert(first[0].properties["source"] == .string("ns_exception"))
assert(first[0].properties["name"] == .string("NSRangeException"))
assert(first[0].appVersion == "1.2.3" && first[0].build == "42")
reporter.write(NSException(name: .rangeException, reason: "second synthetic exception", userInfo: nil))
assert(reporter.takePending(storage: storage).isEmpty)
reporter.disable(deleteReports: true)
print("Fresh-process NSException capture and terminal admission passed")
