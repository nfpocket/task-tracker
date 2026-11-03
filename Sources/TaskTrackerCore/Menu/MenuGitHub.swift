import Foundation

/// The GitHub side of the menu, all through `gh`.
public enum MenuGitHub {
    /// "acme/web" from https://github.com/acme/web.git or git@github.com:acme/web.git.
    public static func repo(fromRemote remote: String) -> String? {
        let pattern = #"github\.com[:/]([^/\s]+)/([^/\s]+?)(\.git)?/?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let owner = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text) else { return nil }
        return "\(text[owner])/\(text[name])"
    }

    /// The last PR address in some text, e.g. what `gh pr create` printed.
    public static func pullRequest(in text: String) -> (repo: String, number: Int)? {
        let pattern = #"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = matches.last,
              let repo = Range(match.range(at: 1), in: text), let number = Range(match.range(at: 2), in: text),
              let value = Int(text[number]) else { return nil }
        return (String(text[repo]), value)
    }

    public static func currentRepo(in directory: String) -> String? {
        guard let remote = try? Shell.run("git", ["-C", directory, "remote", "get-url", "origin"]), remote.ok else { return nil }
        return repo(fromRemote: remote.output)
    }

    public static func currentBranch(in directory: String) -> String? {
        guard let branch = try? Shell.run("git", ["-C", directory, "branch", "--show-current"]), branch.ok,
              !branch.output.isEmpty else { return nil }
        return branch.output
    }

    public struct PRInfo: Decodable, Sendable {
        public var title: String
        public var url: String
        public var state: String
        public var headRefName: String
    }

    public static func prInfo(repo: String, number: Int) throws -> PRInfo {
        let json = try Shell.check("gh", ["pr", "view", "\(number)", "--repo", repo, "--json", "title,url,state,headRefName"])
        return try JSONDecoder().decode(PRInfo.self, from: Data(json.utf8))
    }

    /// Posts a comment on a PR and returns its address.
    public static func comment(repo: String, pr: Int, body: String) throws -> String {
        try Shell.check("gh", ["pr", "comment", "\(pr)", "--repo", repo, "--body", body])
    }

    public struct CreatedIssue: Sendable {
        public var number: Int
        public var url: String
        /// Set when the issue exists but couldn't be put on the project board.
        public var warning: String?
    }

    /// Creates an issue and, when the config names a project for the repo, puts it on that board.
    public static func createIssue(repo: String, title: String, body: String, config: MenuConfig) throws -> CreatedIssue {
        let url = try Shell.check("gh", ["issue", "create", "--repo", repo, "--title", title, "--body", body])
        guard let number = url.split(separator: "/").last.flatMap({ Int($0) }) else {
            throw MenuError("gh issue create printed no issue address: \(url)")
        }
        var issue = CreatedIssue(number: number, url: url)
        if let project = config.projects[repo] {
            do {
                let item = try Shell.check("gh", [
                    "project", "item-add", "\(project.number)", "--owner", project.owner,
                    "--url", url, "--format", "json", "--jq", ".id",
                ])
                try Shell.check("gh", [
                    "project", "item-edit", "--id", item, "--project-id", project.projectId,
                    "--field-id", project.statusField, "--single-select-option-id", project.statusOption,
                ])
            } catch {
                issue.warning = "Issue #\(number) was created, but not put on the board: \(error.localizedDescription)"
            }
        }
        return issue
    }

    // MARK: - Texts

    static func problemComment(for item: MenuItem, problem: String) -> String {
        """
        **Checked by hand: problem found**

        > \(item.text)

        \(problem)

        <sub>From the Task Tracker menu (\(item.id)). Fix it in this PR, then put the check back with `menu reopen \(item.id) --note "fixed in <sha>"`.</sub>
        """
    }

    static func problemIssue(for item: MenuItem, problem: String) -> (title: String, body: String) {
        let firstLine = problem.split(separator: "\n").first.map(String.init) ?? problem
        let title = "After #\(item.pr): \(shortened(firstLine, to: 90))"
        var body = """
        Found while checking #\(item.pr) by hand, after it was merged.

        **Check:** \(item.text)

        **Problem:** \(problem)
        """
        if let why = item.why { body += "\n\n**Why it needed a person:** \(why)" }
        body += "\n\n<sub>From the Task Tracker menu (\(item.id)).</sub>"
        return (title, body)
    }

    static func ideaIssue(for item: MenuItem) -> (title: String, body: String) {
        var body = item.text
        if let why = item.why { body += "\n\n\(why)" }
        body += "\n\nCame up while building #\(item.pr).\n\n<sub>From the Task Tracker menu (\(item.id)).</sub>"
        return (shortened(item.text, to: 120), body)
    }

    static func shortened(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        let cut = text.prefix(length)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}
