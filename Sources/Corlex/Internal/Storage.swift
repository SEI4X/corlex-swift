import Foundation

/// The folder the SDK keeps its files in: `Application Support/Corlex`. Files, not
/// `UserDefaults`: the SDK can describe exactly what it wrote. OwnerChoices separately declares
/// its fstat file-metadata check under the own-container C617.1 reason. The folder is excluded
/// from backups: a restored anonymous id would put two devices under one person.
struct Storage {
    let directory: URL
    let scope: StorageScope?

    init(directory: URL, scope: StorageScope? = nil) {
        self.directory = directory
        self.scope = scope
    }

    static func bound(scope: StorageScope) -> Storage? {
        guard let directory = scope.ledger.scope(owner: scope.owner, record: scope.record) else { return nil }
        return Storage(directory: directory, scope: scope)
    }

    func authorized<T>(_ action: () -> T) -> T? {
        if let scope { return scope.authorized(action) }
        return action()
    }

    /// `Application Support/Corlex`, or nil when the system gives no such folder.
    static func standard() -> Storage? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return Storage(directory: base.appendingPathComponent("Corlex", isDirectory: true))
    }

    func url(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    /// Folder paths are returned only while current; actual file operations also hold the fence.
    @discardableResult
    func prepare(subfolder: String? = nil) -> URL? {
        authorized { prepareUnlocked(subfolder: subfolder) } ?? nil
    }

    private func prepareUnlocked(subfolder: String? = nil) -> URL? {
        guard subfolder.map(validName) ?? true else { return nil }
        let target = subfolder.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try protect(directory, directory: true)
            if target != directory { try protect(target, directory: true) }
            return target
        } catch { return nil }
    }

    private func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.utf8.contains(0)
    }

    private func protect(_ url: URL, directory: Bool) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: directory ? 0o700 : 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    func readText(_ name: String) -> String? {
        guard let data = read(name) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func writeText(_ text: String, to name: String) {
        write(Data(text.utf8), to: name)
    }

    func read(_ name: String, limit: Int = 2 * 1024 * 1024) -> Data? {
        guard validName(name), limit >= 0, limit <= 2 * 1024 * 1024 else { return nil }
        return authorized { readUnlocked(name, limit: limit) } ?? nil
    }

    private func readUnlocked(_ name: String, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url(name)) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        do {
            while let chunk = try handle.read(upToCount: min(8192, limit + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk)
                if data.count > limit { return nil }
            }
            return data
        } catch { return nil }
    }

    func write(_ data: Data, to name: String) {
        guard validName(name), data.count <= 2 * 1024 * 1024 else { return }
        _ = authorized {
            guard prepareUnlocked() != nil else { return }
            do {
                try data.write(to: url(name), options: .atomic)
                try protect(url(name), directory: false)
            } catch { return }
        }
    }

    func append(_ data: Data, to name: String) {
        guard validName(name) else { return }
        _ = authorized {
            guard prepareUnlocked() != nil else { return }
            let destination = url(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: destination) else { return }
            defer { try? handle.close() }
            do {
                try protect(destination, directory: false)
                let length = try handle.seekToEnd()
                guard length + UInt64(data.count) <= 2 * 1024 * 1024 else { return }
                try handle.write(contentsOf: data)
            } catch { return }
        }
    }

    func remove(_ name: String) {
        guard validName(name) else { return }
        _ = authorized { try? FileManager.default.removeItem(at: url(name)) }
    }

    /// Bound storage can erase only its own current physical scope. Ledger revoke erases all.
    func wipe() {
        _ = authorized { try? FileManager.default.removeItem(at: directory) }
    }
}
