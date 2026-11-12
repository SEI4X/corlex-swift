import Foundation
import CoreFoundation

/// A crash report found on disk, ready to become a `corlex.crash` event.
struct CapturedCrash: Equatable {
    var crashId: String
    var timestamp: Date
    var appVersion: String?
    var osVersion: String?
    var build: String?
    var properties: [String: JSONValue]
}

/// Reads the file the crash handlers write:
///
///     {"v":1,"crash_id":"…","kind":"native","fatal":true,"arch":"arm64",…,"source":"signal",
///      "name":"SIGSEGV","message":"Signal 11","timestamp_ms":1761000000000}
///     F<TAB>debug_id<TAB>image_addr<TAB>addr<TAB>image[<TAB>function]
///     …
///
/// and turns it into the properties of the event (services/ingest/docs/protocol.md §4).
enum CrashReportReader {
    static func parse(_ data: Data, captureErrorMessages: Bool = false) -> CapturedCrash? {
        guard data.count < 512 * 1024, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first,
              let header = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              let crashId = header["crash_id"] as? String, crashId.count == 36, UUID(uuidString: crashId) != nil,
              let timestamp = header["timestamp_ms"] as? NSNumber, CFGetTypeID(timestamp) != CFBooleanGetTypeID(),
              timestamp.doubleValue.isFinite, (0...253402300799999).contains(timestamp.doubleValue) else { return nil }
        let millis = timestamp.doubleValue
        let frames = lines.dropFirst().prefix(Limits.maxCrashFrames).compactMap(frame(from:))
        let message = NativeCrashPrivacy.message(header["message"] as? String, detailed: captureErrorMessages)
        var properties: [String: JSONValue] = [
            "crash_id": .string(crashId),
            "kind": .string("native"),
            "fatal": .bool(true),
            "name": .string(NativeCrashPrivacy.name(header["name"] as? String)),
            "message": .string(message),
            "source": .string(header["source"] as? String == "ns_exception" ? "ns_exception" : "signal"),
            "frames": .array(frames),
            "symbolicated": .bool(false),
        ]
        if let arch = header["arch"] as? String, ["arm64", "x86_64", "armv7"].contains(arch) { properties["arch"] = .string(arch) }
        return CapturedCrash(
            crashId: crashId,
            timestamp: Date(timeIntervalSince1970: millis / 1000),
            appVersion: NativeCrashPrivacy.metadata(header["app_version"] as? String, limit: 128),
            osVersion: header["os_version"] as? String,
            build: NativeCrashPrivacy.metadata(header["build"] as? String, limit: 32),
            properties: properties
        )
    }

    private static func address(_ value: String) -> Bool {
        value.range(of: #"^0x[0-9a-fA-F]{1,16}$"#, options: .regularExpression) != nil
    }

    /// `F\tdebug_id\timage_addr\taddr\timage[\tfn]`; an address outside every image keeps only `addr` and `fn`.
    private static func frame(from line: Substring) -> JSONValue? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5, fields[0] == "F", address(fields[3]) else { return nil }
        var frame: [String: JSONValue] = ["addr": .string(fields[3])]
        if fields[1] != "-", fields[1].count == 36, UUID(uuidString: fields[1]) != nil, address(fields[2]) {
            frame["debug_id"] = .string(fields[1])
            frame["image_addr"] = .string(fields[2])
        }
        if let image = NativeCrashPrivacy.image(fields[4]), image != "-" { frame["image"] = .string(image) }
        if fields.count >= 6, let function = NativeCrashPrivacy.function(fields[5]) { frame["fn"] = .string(function) }
        return .object(frame)
    }
}
