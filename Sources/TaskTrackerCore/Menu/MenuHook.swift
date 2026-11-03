import Foundation

/// The Claude Code PostToolUse hook. When a Bash call ran `gh pr create` and printed a PR address,
/// it remembers the PR and the session, and tells the agent to put its checks and ideas on the menu.
public enum MenuHook {
    public static func instruction(repo: String, pr: Int) -> String {
        """
        PR #\(pr) is open. Put on the user's menu (Task Tracker) what a person has to check by hand, with the `menu` command (`menu help` lists everything):
        - each check you could not verify yourself, at most 4: `menu add \(pr) check "<one action, and what should happen>" --why "<what was decided, and why you couldn't verify it yourself>" --where "<a URL, the branch, or prod>" --min <minutes> --repo \(repo)`
        - each idea you noticed but left out of scope: `menu add \(pr) idea "<the idea>" --why "<what made you think of it>" --repo \(repo)`
        Write each check so it can be done in a few minutes without reading the diff. Quote UI labels exactly. If nothing on this PR needs a person, say so in one line and add nothing.
        """
    }

    /// The hook's stdout for one event, or nil when it has nothing to say.
    public static func handle(_ input: Data, actions: MenuActions, lookUpPR: Bool = true) -> String? {
        guard let event = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              (event["hook_event_name"] as? String) == "PostToolUse",
              (event["tool_name"] as? String) == "Bash",
              let command = (event["tool_input"] as? [String: Any])?["command"] as? String,
              command.range(of: #"\bgh\s+pr\s+create\b"#, options: .regularExpression) != nil else { return nil }

        let printed = strings(in: event["tool_response"] as Any).joined(separator: "\n")
        guard let found = MenuGitHub.pullRequest(in: printed) else { return nil }

        let info = lookUpPR ? try? MenuGitHub.prInfo(repo: found.repo, number: found.number) : nil
        try? actions.registerPR(
            repo: found.repo, number: found.number,
            session: event["session_id"] as? String, cwd: event["cwd"] as? String, info: info
        )

        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PostToolUse",
                "additionalContext": instruction(repo: found.repo, pr: found.number),
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Every string inside a JSON value: the tool's output may be a string or an object of them.
    static func strings(in value: Any) -> [String] {
        switch value {
        case let text as String: [text]
        case let object as [String: Any]: object.values.flatMap(strings(in:))
        case let array as [Any]: array.flatMap(strings(in:))
        default: []
        }
    }
}
