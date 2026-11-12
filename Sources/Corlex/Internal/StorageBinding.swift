import CryptoKit
import Foundation

/// Local storage partition only; the server still authenticates every SDK request.
enum StorageBinding {
    static func validKey(_ key: String) -> Bool {
        guard key.utf8.count == 51, key.hasPrefix("ck_live_") || key.hasPrefix("ck_test_") else { return false }
        return key.utf8.dropFirst(8).allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    static func canonical(_ url: URL, allowInsecureHttp: Bool = false) -> String? {
        guard EndpointPolicy.allowed(url, allowInsecureHttp: allowInsecureHttp),
              var parts = URLComponents(url: url.standardized, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        guard var text = parts.url?.absoluteString else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func digest(key: String, endpoint: URL, configEndpoint: URL, allowInsecureHttp: Bool = false) -> String? {
        guard validKey(key), let ingest = canonical(endpoint, allowInsecureHttp: allowInsecureHttp),
              let config = canonical(configEndpoint, allowInsecureHttp: allowInsecureHttp),
              let bytes = try? JSONSerialization.data(withJSONObject: [key, ingest, config], options: [.withoutEscapingSlashes]) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
