import Foundation

/// Runs command-line tools (gh, git, osascript, ps). An app started from Finder gets a bare PATH,
/// so the usual install folders are added to it.
public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String

        public var ok: Bool { status == 0 }
        public var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public static var path: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (current + extra).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Runs `tool` with `arguments` and waits for it.
    public static func run(_ tool: String, _ arguments: [String], in directory: String? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        // gh would otherwise page or prompt.
        environment["GH_PAGER"] = ""
        environment["GH_PROMPT_DISABLED"] = "1"
        process.environment = environment
        if let directory, FileManager.default.fileExists(atPath: directory) {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Read both pipes at once so neither fills up and blocks the tool.
        let collected = Collected()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collected.stdout = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: collected.stdout, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Like `run`, but a failure throws with the tool's own message.
    @discardableResult
    public static func check(_ tool: String, _ arguments: [String], in directory: String? = nil) throws -> String {
        let result = try run(tool, arguments, in: directory)
        guard result.ok else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MenuError("\(tool) \(arguments.first ?? "") failed: \(message.isEmpty ? "exit \(result.status)" : message)")
        }
        return result.output
    }

    private final class Collected: @unchecked Sendable {
        var stdout = Data()
    }
}
