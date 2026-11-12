import Foundation

enum NativeCrashPrivacy {
    static let omitted = "Error details omitted"
    static func name(_ value: String?) -> String {
        let known: Set<String> = ["SIGABRT", "SIGSEGV", "SIGBUS", "SIGILL", "SIGFPE", "SIGTRAP",
            "NSInvalidArgumentException", "NSRangeException", "NSInternalInconsistencyException", "NSGenericException", "NSMallocException"]
        return value.flatMap { known.contains($0) ? $0 : nil } ?? "NativeError"
    }
    static func message(_ value: String?, detailed: Bool) -> String {
        detailed ? (value ?? "").truncated(toUTF8Bytes: Limits.maxCrashMessage) : omitted
    }
    static func metadata(_ value: String?, limit: Int) -> String {
        guard let value, value.utf8.count <= limit else { return "" }
        return value
    }
    static func image(_ value: String) -> String? {
        let basename = (value as NSString).lastPathComponent
        return basename.range(of: #"^[A-Za-z0-9_.+-]{1,128}$"#, options: .regularExpression) == nil ? nil : basename
    }
    static func function(_ value: String) -> String? {
        guard value.utf8.count <= 256,
              value.range(of: #"^[A-Za-z0-9_$.:\[\]()+<>,~ -]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
    static func matches(_ data: Data, scope: StorageScope?) -> Bool {
        guard let scope else { return true } // standalone file-format probes, never a bound client
        guard scope.isCurrent, let line = data.split(separator: 0x0a).first,
              let header = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return false }
        return header["owner"] as? String == scope.owner && header["generation"] as? String == scope.record.generation
    }
}
