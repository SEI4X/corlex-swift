import Foundation

struct ToolError: Error, CustomStringConvertible {
    let description: String
}

/// Runs the Xcode command line tools (`xcrun nm`, `xcrun dwarfdump`, ...), which are present on
/// every machine that can build an iOS app.
enum ProcessRunner {
    /// Output of a tool, all at once. Fine for `nm`, `otool` and `dwarfdump --uuid`.
    static func output(_ tool: String, _ arguments: [String], stdin: String? = nil) throws -> String {
        var text = ""
        try stream(tool, arguments, stdin: stdin) { text += $0 + "\n" }
        return text
    }

    /// Calls `onLine` for every output line while the tool runs, so `dwarfdump --debug-line` of a
    /// big app (hundreds of MB of text) never has to fit in memory.
    static func stream(
        _ tool: String, _ arguments: [String], stdin: String? = nil, onLine: (String) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [tool] + arguments
        let out = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()
        if let stdin {
            // Written from another thread: a big input would otherwise fill the pipe and deadlock.
            DispatchQueue.global().async {
                input.fileHandleForWriting.write(Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
        }
        var pending = Data()
        while true {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0a) {
                onLine(String(decoding: pending[start..<newline], as: UTF8.self))
                start = newline + 1
            }
            pending = Data(pending[start...])
        }
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolError(description: "\(tool) exited with status \(process.terminationStatus)")
        }
    }
}
