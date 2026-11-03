import Foundation

/// Sends the problems found on a PR back to the Claude Code session that built it, in Ghostty:
/// - that session is still open in a tab → focus the tab and type the prompt into it;
/// - it's closed → a new tab in its folder, `claude --resume <session> "<prompt>"`;
/// - it's gone → a new tab in the PR's folder with a fresh session and the same prompt;
/// - no folder left → the prompt goes on the clipboard.
public enum MenuFix {
    public enum Outcome: Equatable, Sendable {
        case typedIntoOpenSession
        case resumedInNewTab
        case freshSessionInNewTab
        case copiedToClipboard(reason: String)

        public var message: String {
            switch self {
            case .typedIntoOpenSession: "Sent to its session, which was still open."
            case .resumedInNewTab: "Resumed its session in a new Ghostty tab."
            case .freshSessionInNewTab: "Its session is gone: started a new one in a Ghostty tab."
            case .copiedToClipboard(let reason): "\(reason) The prompt is on the clipboard."
            }
        }
    }

    public static func prompt(pr: MenuPR, problems: [MenuItem]) -> String {
        var lines = ["Fix what I found on PR #\(pr.number) while checking it by hand:", ""]
        for item in problems {
            lines.append("- \(item.id): \(item.text)")
            lines.append("  Problem: \((item.problem ?? "").replacingOccurrences(of: "\n", with: " "))")
        }
        lines.append("")
        lines.append(
            "Each problem is also a comment on the PR. Fix them on this PR's branch, push, and answer each comment. "
                + "Then put each fixed check back on my menu: menu reopen <id> --note \"fixed in <short sha>\"."
        )
        return lines.joined(separator: "\n")
    }

    /// Hands `prompt` to the session that built `pr`.
    public static func send(_ prompt: String, for pr: MenuPR, promptDirectory: URL) throws -> Outcome {
        if let session = pr.session, let live = ClaudeSessions.live(session), let tty = ClaudeSessions.tty(of: live.pid) {
            if try Ghostty.type(prompt, intoTerminalWithTTY: tty) { return .typedIntoOpenSession }
        }

        // Pass the prompt through a file: it has several lines and quotes.
        try FileManager.default.createDirectory(at: promptDirectory, withIntermediateDirectories: true)
        let file = promptDirectory.appending(path: "pr-\(pr.number)-\(Int(Date.now.timeIntervalSince1970)).txt")
        try prompt.write(to: file, atomically: true, encoding: .utf8)
        let quotedPrompt = "\"$(cat \(shellQuoted(file.path)))\""

        if let session = pr.session, let folder = ClaudeSessions.startFolder(of: session),
           FileManager.default.fileExists(atPath: folder) {
            try Ghostty.newTab(in: folder, typing: "claude --resume \(shellQuoted(session)) \(quotedPrompt)\n")
            return .resumedInNewTab
        }
        if let folder = pr.cwd, FileManager.default.fileExists(atPath: folder) {
            try Ghostty.newTab(in: folder, typing: "claude \(quotedPrompt)\n")
            return .freshSessionInNewTab
        }
        try Shell.check("sh", ["-c", "pbcopy < \(shellQuoted(file.path))"])
        return .copiedToClipboard(reason: "Couldn't find the session or the folder of PR #\(pr.number).")
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// What Claude Code keeps about its sessions under ~/.claude.
public enum ClaudeSessions {
    public struct Live: Decodable, Sendable {
        public var pid: Int32
        public var sessionId: String
        public var cwd: String?
        public var status: String?
    }

    static var claudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude", directoryHint: .isDirectory)
    }

    /// The running Claude Code process for a session, from ~/.claude/sessions/<pid>.json.
    public static func live(_ sessionID: String) -> Live? {
        let folder = claudeDirectory.appending(path: "sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: folder.appending(path: name)),
                  let session = try? JSONDecoder().decode(Live.self, from: data),
                  session.sessionId == sessionID, kill(session.pid, 0) == 0 else { continue }
            return session
        }
        return nil
    }

    /// "/dev/ttys016" for a process, or nil when it has no terminal.
    public static func tty(of pid: Int32) -> String? {
        guard let result = try? Shell.run("ps", ["-o", "tty=", "-p", "\(pid)"]), result.ok else { return nil }
        let name = result.output
        guard !name.isEmpty, name != "??" else { return nil }
        return name.hasPrefix("/dev/") ? name : "/dev/\(name)"
    }

    /// The folder a session was started in: `claude --resume` only finds a session from there.
    /// Read from the first lines of its transcript, ~/.claude/projects/<folder>/<session>.jsonl.
    public static func startFolder(of sessionID: String) -> String? {
        let projects = claudeDirectory.appending(path: "projects")
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return nil }
        for folder in folders {
            let transcript = projects.appending(path: folder).appending(path: "\(sessionID).jsonl")
            guard let handle = try? FileHandle(forReadingFrom: transcript) else { continue }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
            for line in head.split(separator: UInt8(ascii: "\n")) {
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   let cwd = object["cwd"] as? String {
                    return cwd
                }
            }
        }
        return nil
    }
}

/// Ghostty's AppleScript interface (Ghostty 1.2 and later).
public enum Ghostty {
    /// Focuses the terminal on `tty`, types `text` into it as a paste, and presses Return.
    /// Returns false when no Ghostty terminal has that tty.
    public static func type(_ text: String, intoTerminalWithTTY tty: String) throws -> Bool {
        let script = """
        on run argv
            tell application "Ghostty"
                set matches to (every terminal whose tty is (item 1 of argv))
                if (count of matches) is 0 then return "missing"
                set target to item 1 of matches
                focus target
                input text (item 2 of argv) to target
                delay 0.2
                send key "enter" to target
                activate
            end tell
            return "ok"
        end run
        """
        return try Shell.check("osascript", ["-e", script, tty, text]) == "ok"
    }

    /// Opens a tab in the front window (or a new window) in `folder` and types `input` into its shell.
    public static func newTab(in folder: String, typing input: String) throws {
        let script = """
        on run argv
            tell application "Ghostty"
                set config to new surface configuration
                set initial working directory of config to (item 1 of argv)
                set initial input of config to (item 2 of argv)
                if (count of windows) > 0 then
                    new tab in front window with configuration config
                else
                    new window with configuration config
                end if
                activate
            end tell
        end run
        """
        try Shell.check("osascript", ["-e", script, folder, input])
    }
}
