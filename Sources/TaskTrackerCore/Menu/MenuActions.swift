import Foundation

/// Everything you or an agent can do with the menu. The `menu` command and the app both call these,
/// so a button and a command always do the same thing.
public struct MenuActions: Sendable {
    public let store: MenuStore

    public init(store: MenuStore = MenuStore()) {
        self.store = store
    }

    // MARK: - Agents

    /// Puts a check or an idea on the menu. `session` and `cwd` record who built the PR, if nobody has yet.
    public func add(
        repo: String, pr: Int, kind: MenuKind, text: String, why: String? = nil, location: String? = nil,
        minutes: Int? = nil, session: String? = nil, cwd: String? = nil
    ) throws -> MenuFile.AddResult {
        try store.update { file in
            let result = file.add(repo: repo, pr: pr, kind: kind, text: text, why: why, location: location, minutes: minutes)
            file.updatePR(repo, pr) { record in
                if record.session == nil { record.session = session.nonEmpty }
                if record.cwd == nil { record.cwd = cwd.nonEmpty }
            }
            return result
        }
    }

    /// Called by the hook right after `gh pr create`: remembers the PR and the session that opened it.
    public func registerPR(repo: String, number: Int, session: String?, cwd: String?, info: MenuGitHub.PRInfo?) throws {
        try store.update { file in
            file.updatePR(repo, number) { record in
                record.session = session.nonEmpty ?? record.session
                record.cwd = cwd.nonEmpty ?? record.cwd
                if let info {
                    record.title = info.title
                    record.url = info.url
                    record.branch = info.headRefName
                    record.state = PRState(github: info.state)
                    record.checkedAt = .now
                }
            }
        }
    }

    /// Finds the PR a number means: the only one with that number, else the one in `repo`.
    public func pr(_ number: Int, repo: String? = nil) throws -> MenuPR {
        let file = try store.read()
        let matches = file.prs.filter { $0.number == number && (repo == nil || $0.repo == repo) }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty { throw MenuError("PR #\(number) has nothing on the menu.") }
        throw MenuError("Several repos have a PR #\(number) on the menu: pass --repo.")
    }

    // MARK: - Deciding

    @discardableResult
    public func setStatus(_ id: String, to status: MenuItemStatus) throws -> MenuItem {
        try store.update { file in
            guard let item = file.updateItem(id, { $0.status = status }) else { throw MenuError("No item \(id) on the menu.") }
            return item
        }
    }

    /// Takes items off the menu for good (see `MenuFile.remove`).
    @discardableResult
    public func delete(_ ids: [String]) throws -> MenuRemoval {
        try store.update { file in
            let removal = file.remove(Set(ids))
            guard !removal.items.isEmpty else { throw MenuError("No item \(ids.joined(separator: ", ")) on the menu.") }
            return removal
        }
    }

    public func restore(_ removal: MenuRemoval) throws {
        try store.update { $0.restore(removal) }
    }

    /// Puts a check back after a fix: "fixed in 4e1a2b".
    @discardableResult
    public func reopen(_ id: String, note: String?) throws -> MenuItem {
        try store.update { file in
            guard let item = file.updateItem(id, { item in
                item.status = .open
                item.note = note.nonEmpty
            }) else { throw MenuError("No item \(id) on the menu.") }
            return item
        }
    }

    public struct Reported: Sendable {
        public var item: MenuItem
        public var message: String
    }

    /// A check didn't work. On an open PR the problem becomes a comment there, to be fixed in that PR;
    /// on a merged or closed PR it becomes a new issue.
    public func reportProblem(_ id: String, _ problem: String) throws -> Reported {
        let text = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MenuError("Write what's wrong first.") }
        guard let item = try store.read().item(id) else { throw MenuError("No item \(id) on the menu.") }

        let info = try MenuGitHub.prInfo(repo: item.repo, number: item.pr)
        let state = PRState(github: info.state) ?? .open
        try store.update { file in
            file.updatePR(item.repo, item.pr) { record in
                record.state = state
                record.title = info.title
                record.url = info.url
                record.checkedAt = .now
            }
        }

        if state == .open {
            let url = try MenuGitHub.comment(repo: item.repo, pr: item.pr, body: MenuGitHub.problemComment(for: item, problem: text))
            let updated = try store.update { file in
                file.updateItem(id) { item in
                    item.status = .problem
                    item.problem = text
                    item.link = url
                    item.note = nil
                }!
            }
            return Reported(item: updated, message: "Posted on PR #\(item.pr).")
        }

        let issue = MenuGitHub.problemIssue(for: item, problem: text)
        let created = try MenuGitHub.createIssue(repo: item.repo, title: issue.title, body: issue.body, config: store.config())
        let updated = try store.update { file in
            file.updateItem(id) { item in
                item.status = .issue
                item.problem = text
                item.issue = created.number
                item.link = created.url
            }!
        }
        return Reported(item: updated, message: created.warning ?? "PR #\(item.pr) is \(state.rawValue): made issue #\(created.number).")
    }

    /// An idea becomes an issue (on the repo's board, if the config names one).
    public func makeIssue(_ id: String) throws -> Reported {
        guard let item = try store.read().item(id) else { throw MenuError("No item \(id) on the menu.") }
        let issue = MenuGitHub.ideaIssue(for: item)
        let created = try MenuGitHub.createIssue(repo: item.repo, title: issue.title, body: issue.body, config: store.config())
        let updated = try store.update { file in
            file.updateItem(id) { item in
                item.status = .issue
                item.issue = created.number
                item.link = created.url
            }!
        }
        return Reported(item: updated, message: created.warning ?? "Made issue #\(created.number).")
    }

    /// Sends the problems waiting on a PR to the session that built it.
    public func fix(_ pr: MenuPR) throws -> MenuFix.Outcome {
        let file = try store.read()
        let record = file.pr(pr.repo, pr.number) ?? pr
        let problems = file.items.filter { $0.repo == pr.repo && $0.pr == pr.number && $0.status == .problem }
        guard !problems.isEmpty else { throw MenuError("No problems waiting on PR #\(pr.number).") }

        let prompt = MenuFix.prompt(pr: record, problems: problems)
        let outcome = try MenuFix.send(prompt, for: record, promptDirectory: store.directory.appending(path: "menu-prompts"))
        if case .copiedToClipboard = outcome { return outcome }
        try store.update { file in
            for item in problems { file.updateItem(item.id) { $0.status = .fixing } }
            file.updatePR(pr.repo, pr.number) { $0.fixStartedAt = .now }
        }
        return outcome
    }

    // MARK: - Keeping PRs current

    /// Asks GitHub whether the PRs with open items are still open. Skips any checked within `maxAge`.
    public func refresh(maxAge: TimeInterval = 300) throws {
        let file = try store.read()
        let wanted = Set(file.items.filter { !$0.status.isSettled }.map { "\($0.repo)#\($0.pr)" })
        let stale = file.prs.filter { wanted.contains($0.id) && Date.now.timeIntervalSince($0.checkedAt ?? .distantPast) > maxAge }
        for pr in stale {
            guard let info = try? MenuGitHub.prInfo(repo: pr.repo, number: pr.number) else { continue }
            try store.update { file in
                file.updatePR(pr.repo, pr.number) { record in
                    record.title = info.title
                    record.url = info.url
                    record.branch = info.headRefName
                    record.state = PRState(github: info.state)
                    record.checkedAt = .now
                }
            }
        }
    }
}
