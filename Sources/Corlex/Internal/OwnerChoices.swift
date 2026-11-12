import Darwin
import Foundation

/// Privacy bookkeeping only. Callers hold PrivacyLedger's filesystem lock.
struct OwnerChoices {
    let root: URL
    private let name = "owner-choices.json"
    private enum Read { case missing, invalid, valid([String]) }
    private enum Bytes {
        case missing, invalid, data(Data)
        var value: Data? { if case .data(let bytes) = self { return bytes }; return nil }
    }
    private static let maximumBytes = 32 * 1024
    private static let maximumOwners = 256

    static func valid(_ owner: String) -> Bool {
        owner.utf8.count == 64 && owner.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func contains(_ owner: String, legacy: URL? = nil) -> Bool {
        guard Self.valid(owner) else { return false }
        switch read() {
        case .valid(let owners): return owners.contains(owner)
        case .invalid: return false
        case .missing:
            // Only a previously bound/current granted scope can supply this migration marker.
            guard let legacy, bounded(legacy, limit: 7).value == Data("granted".utf8) else { return false }
            return grant(owner)
        }
    }

    func grant(_ owner: String) -> Bool {
        guard Self.valid(owner) else { return false }
        var owners: [String] = []
        if case .valid(let saved) = read() { owners = saved }
        if !owners.contains(owner) { owners.append(owner) }
        return write(owners.sorted())
    }

    func clear() -> Bool { write([]) }

    private func read() -> Read {
        let url = root.appendingPathComponent(name)
        let bytes: Data
        switch bounded(url, limit: Self.maximumBytes) {
        case .missing: return .missing
        case .invalid: return .invalid
        case .data(let value): bytes = value
        }
        guard let rows = try? JSONSerialization.jsonObject(with: bytes) as? [[String: String]],
              rows.count <= Self.maximumOwners,
              rows.allSatisfy({ Set($0.keys) == ["owner", "choice"] && $0["choice"] == "granted" }),
              rows.allSatisfy({ Self.valid($0["owner"] ?? "") }) else { return .invalid }
        let owners = rows.compactMap { $0["owner"] }
        guard Set(owners).count == owners.count, owners == owners.sorted(), encode(owners) == bytes else { return .invalid }
        return .valid(owners)
    }

    private func encode(_ owners: [String]) -> Data? {
        try? JSONSerialization.data(withJSONObject: owners.map { ["owner": $0, "choice": "granted"] }, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func write(_ owners: [String]) -> Bool {
        guard owners.count <= Self.maximumOwners, let bytes = encode(owners), bytes.count <= Self.maximumBytes else { return false }
        Storage(directory: root).write(bytes, to: name)
        return bounded(root.appendingPathComponent(name), limit: Self.maximumBytes).value == bytes
    }

    private func bounded(_ url: URL, limit: Int) -> Bytes {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .invalid }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return .invalid }
        var bytes = [UInt8](repeating: 0, count: limit + 1)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, count <= limit else { return .invalid }
        return .data(Data(bytes.prefix(count)))
    }
}
