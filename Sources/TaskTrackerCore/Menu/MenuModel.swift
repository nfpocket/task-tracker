import Foundation

// The menu: things to do by hand while an agent works. An agent that opens a PR puts on it what
// it could not verify itself (checks) and what it noticed but left out of scope (ideas); you
// work through them in the gaps and decide each one.

public enum MenuKind: String, Codable, Sendable, CaseIterable {
    case check, idea
}

public enum MenuItemStatus: String, Codable, Sendable {
    /// Waiting for you.
    case open
    /// Checked: it works.
    case works
    /// A problem was posted on the PR, waiting for a fix there.
    case problem
    /// A session was started to fix the problem.
    case fixing
    /// Turned into an issue.
    case issue
    /// Set aside.
    case later
    /// Not wanted. Kept so the same idea isn't proposed again.
    case dismissed

    /// Done with, from your side.
    public var isSettled: Bool {
        switch self {
        case .works, .issue, .dismissed: true
        case .open, .problem, .fixing, .later: false
        }
    }

    public var label: String {
        switch self {
        case .open: "open"
        case .works: "works"
        case .problem: "sent to PR"
        case .fixing: "being fixed"
        case .issue: "issue"
        case .later: "later"
        case .dismissed: "dismissed"
        }
    }
}

public struct MenuItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var repo: String
    public var pr: Int
    public var kind: MenuKind
    /// For a check: one action and what should happen. For an idea: the idea.
    public var text: String
    /// What was decided, and why the agent couldn't verify it itself.
    public var why: String?
    /// Where to check it: a URL, a branch, prod.
    public var location: String?
    public var minutes: Int?
    public var status: MenuItemStatus
    /// Set when a fix comes back: "fixed in 4e1a2b".
    public var note: String?
    /// What you wrote when it didn't work.
    public var problem: String?
    public var issue: Int?
    /// The PR comment or issue it became.
    public var link: String?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, repo, pr, kind, text, why, minutes, status, note, problem, issue, link, createdAt, updatedAt
        case location = "where"
    }

    /// The number in the id: ids count up, so it orders items by when they were added.
    public var number: Int { Int(id.dropFirst()) ?? 0 }

    /// The first web address in `location`; "localhost:3000" counts as http://localhost:3000.
    public var openURL: URL? {
        guard let location else { return nil }
        let pattern = #"(https?://[^\s,;)]+)|((localhost|127\.0\.0\.1)(:\d+)?(/[^\s,;)]*)?)"#
        guard let range = location.range(of: pattern, options: .regularExpression) else { return nil }
        let found = String(location[range])
        return URL(string: found.hasPrefix("http") ? found : "http://\(found)")
    }
}

public enum PRState: String, Codable, Sendable {
    case open, merged, closed

    init?(github: String) {
        self.init(rawValue: github.lowercased())
    }
}

/// A PR with items on the menu, and the session that built it, so a fix can go back to it.
public struct MenuPR: Codable, Identifiable, Equatable, Sendable {
    public var repo: String
    public var number: Int
    public var title: String?
    public var url: String?
    public var branch: String?
    public var state: PRState?
    /// The Claude Code session that opened the PR.
    public var session: String?
    /// The folder that session worked in.
    public var cwd: String?
    public var fixStartedAt: Date?
    public var checkedAt: Date?

    public var id: String { "\(repo)#\(number)" }
}

public struct MenuRemoval: Equatable, Sendable {
    public var items: [MenuItem]
    public var prs: [MenuPR]
}

public struct MenuFile: Codable, Equatable, Sendable {
    public var version = 1
    public var nextID = 1
    public var prs: [MenuPR] = []
    public var items: [MenuItem] = []

    public init() {}

    public func pr(_ repo: String, _ number: Int) -> MenuPR? {
        prs.first { $0.repo == repo && $0.number == number }
    }

    public func item(_ id: String) -> MenuItem? {
        items.first { $0.id == id }
    }

    public mutating func updatePR(_ repo: String, _ number: Int, _ body: (inout MenuPR) -> Void) {
        if let index = prs.firstIndex(where: { $0.repo == repo && $0.number == number }) {
            body(&prs[index])
        } else {
            var pr = MenuPR(repo: repo, number: number)
            body(&pr)
            prs.append(pr)
        }
    }

    public enum AddResult: Equatable, Sendable {
        case added(MenuItem)
        /// The same text is already on the menu (or was dismissed): nothing was added.
        case duplicate(MenuItem)
    }

    public mutating func add(
        repo: String, pr: Int, kind: MenuKind, text: String,
        why: String? = nil, location: String? = nil, minutes: Int? = nil, now: Date = .now
    ) -> AddResult {
        let key = Self.normalized(text)
        if let existing = items.first(where: { $0.repo == repo && Self.normalized($0.text) == key }) {
            return .duplicate(existing)
        }
        let item = MenuItem(
            id: "m\(nextID)", repo: repo, pr: pr, kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            why: why.nonEmpty, location: location.nonEmpty, minutes: minutes, status: .open,
            createdAt: now, updatedAt: now
        )
        nextID += 1
        items.append(item)
        if self.pr(repo, pr) == nil { prs.append(MenuPR(repo: repo, number: pr)) }
        return .added(item)
    }

    @discardableResult
    public mutating func updateItem(_ id: String, now: Date = .now, _ body: (inout MenuItem) -> Void) -> MenuItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        body(&items[index])
        items[index].updatedAt = now
        return items[index]
    }

    /// What the popover shows: everything still open, plus what was settled in the last hours,
    /// so you see what you just did. Grouped by PR, newest PR first.
    public func visibleGroups(now: Date = .now, keepSettledFor: TimeInterval = 12 * 3600) -> [(pr: MenuPR, items: [MenuItem])] {
        let visible = items.filter { !$0.status.isSettled || now.timeIntervalSince($0.updatedAt) < keepSettledFor }
        var order: [String] = []
        var grouped: [String: [MenuItem]] = [:]
        for item in visible {
            let key = "\(item.repo)#\(item.pr)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        let groups = order.map { key -> (pr: MenuPR, items: [MenuItem]) in
            let first = grouped[key]![0]
            let pr = self.pr(first.repo, first.pr) ?? MenuPR(repo: first.repo, number: first.pr)
            // Checks before ideas, otherwise in the order the agent wrote them (a restored item
            // goes back to its place).
            let sorted = grouped[key]!.sorted { a, b in
                if a.kind != b.kind { return a.kind == .check }
                return a.number < b.number
            }
            return (pr, sorted)
        }
        return groups.sorted { ($0.items.map(\.number).max() ?? 0) > ($1.items.map(\.number).max() ?? 0) }
    }

    /// Takes items off the menu for good, and a PR with nothing left on it. Unlike dismissing,
    /// nothing is remembered: an agent may propose the same thing again.
    public mutating func remove(_ ids: Set<String>) -> MenuRemoval {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        let emptied = prs.filter { pr in
            removed.contains { $0.repo == pr.repo && $0.pr == pr.number }
                && !items.contains { $0.repo == pr.repo && $0.pr == pr.number }
        }
        prs.removeAll { emptied.contains($0) }
        return MenuRemoval(items: removed, prs: emptied)
    }

    /// Puts back what `remove` took, under the same ids.
    public mutating func restore(_ removal: MenuRemoval) {
        for pr in removal.prs where self.pr(pr.repo, pr.number) == nil { prs.append(pr) }
        for item in removal.items where self.item(item.id) == nil { items.append(item) }
    }

    public var openChecks: Int { items.filter { $0.kind == .check && $0.status == .open }.count }
    public var openIdeas: Int { items.filter { $0.kind == .idea && $0.status == .open }.count }

    static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
