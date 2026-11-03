import Foundation

/// The menu's JSON file. The `menu` command (run by agents and hooks) and the app both write it,
/// so every change happens under a file lock: read, change, write, unlock.
public struct MenuStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = MenuStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Next to the task list: `~/Library/Application Support/TaskTracker/menu.json`.
    /// `TASKTRACKER_MENU` points it elsewhere; with only `TASKTRACKER_DATA` set, it sits beside that file.
    public static var defaultFileURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["TASKTRACKER_MENU"] { return URL(fileURLWithPath: override) }
        if let tasks = env["TASKTRACKER_DATA"] {
            return URL(fileURLWithPath: tasks).deletingLastPathComponent().appending(path: "menu.json")
        }
        return URL.applicationSupportDirectory
            .appending(path: "TaskTracker", directoryHint: .isDirectory)
            .appending(path: "menu.json")
    }

    public var directory: URL { fileURL.deletingLastPathComponent() }

    /// Per-repo settings, e.g. which project board new issues go on.
    public var configURL: URL { directory.appending(path: "menu-config.json") }

    public func read() throws -> MenuFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return MenuFile() }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty { return MenuFile() }
        return try Self.decoder.decode(MenuFile.self, from: data)
    }

    /// Reads, lets `body` change the file, and writes it back if it changed, all under the lock.
    @discardableResult
    public func update<Result>(_ body: (inout MenuFile) throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appending(path: ".menu.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw MenuError("Couldn't open \(lockPath)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw MenuError("Couldn't lock \(lockPath)") }
        defer { flock(fd, LOCK_UN) }

        var file = try read()
        let before = file
        let result = try body(&file)
        if file != before {
            let data = try Self.encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
        }
        return result
    }

    public func config() -> MenuConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(MenuConfig.self, from: data) else { return MenuConfig() }
        return config
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// `menu-config.json`: for each repo, the GitHub project new issues land on.
public struct MenuConfig: Codable, Sendable {
    public struct Project: Codable, Sendable {
        /// Org or user that owns the project.
        public var owner: String
        public var number: Int
        public var projectId: String
        public var statusField: String
        /// The status option new issues get, e.g. Backlog.
        public var statusOption: String
    }

    public var projects: [String: Project] = [:]

    public init() {}
}

public struct MenuError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}
