import Foundation

/// Endpoint checks return a diagnostic decision, never an application startup exception.
enum EndpointPolicy {
    static func allowed(_ url: URL, allowInsecureHttp: Bool = false) -> Bool {
        guard url.baseURL == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let hostname = parts.host, !hostname.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !url.absoluteString.contains("\\"), !url.absoluteString.utf8.contains(where: { $0 <= 32 || $0 == 127 }),
              parts.port.map({ (0...65535).contains($0) }) ?? true else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        let host = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if allowInsecureHttp || ["localhost", "::1", "10.0.2.2", "10.0.3.2"].contains(host) { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part).map { (0...255).contains($0) } == true
        }
    }
}
