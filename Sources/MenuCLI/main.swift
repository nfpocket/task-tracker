import Foundation
import TaskTrackerCore

// `menu`: the command agents use to put checks and ideas on the Task Tracker menu, and the one the
// app's buttons share their code with. `menu help` lists everything.

let help = """
menu: things to check by hand while an agent works, shown at the top of Task Tracker.

Agents (after opening a PR):
  menu add <pr> check "<one action, and what should happen>" [--why "…"] [--where "…"] [--min N] [--repo owner/name]
  menu add <pr> idea "<the idea>" [--why "…"] [--repo owner/name]
  menu reopen <id> [--note "fixed in <sha>"]     put a check back after fixing it

Deciding (what the app's buttons do):
  menu works <id>                  the check is fine
  menu problem <id> "<what's wrong>"
                                   open PR: a comment there, fixed in that PR
                                   merged or closed PR: a new issue
  menu issue <id>                  an idea becomes an issue
  menu later <id> | menu dismiss <id>
                                   dismissed items are kept, so they aren't proposed again
  menu delete <id>…                take items off the menu for good
  menu fix <pr> [--repo owner/name]
                                   send the problems on a PR to the session that built it

Looking:
  menu list [--all] [--json]       what's open (--all: settled items too)
  menu show <id>
  menu open <id>                   open the check's address in the browser
  menu refresh                     ask GitHub whether the PRs are still open
  menu path                        where the menu file is

Claude Code:
  menu hook                        PostToolUse hook: reads the event on stdin
"""

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        let booleans: Set<String> = ["all", "json"]
        var index = 0
        while index < raw.count {
            let arg = raw[index]
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if booleans.contains(name) {
                    flags.insert(name)
                } else if index + 1 < raw.count {
                    options[name] = raw[index + 1]
                    index += 1
                } else {
                    options[name] = ""
                }
            } else {
                positional.append(arg)
            }
            index += 1
        }
    }

    func at(_ index: Int, _ what: String) throws -> String {
        guard index < positional.count, !positional[index].isEmpty else { throw MenuError("Missing \(what). See `menu help`.") }
        return positional[index]
    }

    func number(_ index: Int, _ what: String) throws -> Int {
        let text = try at(index, what).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = Int(text) else { throw MenuError("\(what) must be a number, not \(text).") }
        return value
    }
}

let actions = MenuActions()
let env = ProcessInfo.processInfo.environment
let cwd = FileManager.default.currentDirectoryPath

func line(for item: MenuItem) -> String {
    let status = item.status.label.padding(toLength: 11, withPad: " ", startingAt: 0)
    let kind = item.kind.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
    var text = "  \(item.id.padding(toLength: 5, withPad: " ", startingAt: 0)) \(kind) \(status) \(item.text)"
    if let minutes = item.minutes { text += "  [\(minutes) min]" }
    if let note = item.note { text += "  (\(note))" }
    return text
}

func describe(_ item: MenuItem) -> String {
    var lines = ["\(item.id) · \(item.kind.rawValue) · \(item.status.label) · \(item.repo)#\(item.pr)", item.text]
    if let why = item.why { lines.append("why:     \(why)") }
    if let location = item.location { lines.append("where:   \(location)") }
    if let minutes = item.minutes { lines.append("time:    \(minutes) min") }
    if let problem = item.problem { lines.append("problem: \(problem)") }
    if let note = item.note { lines.append("note:    \(note)") }
    if let link = item.link { lines.append("link:    \(link)") }
    return lines.joined(separator: "\n")
}

func repo(for pr: Int, _ args: Arguments) throws -> String {
    if let repo = args.options["repo"], !repo.isEmpty { return repo }
    let file = try actions.store.read()
    let known = Set(file.prs.filter { $0.number == pr }.map(\.repo))
    let here = MenuGitHub.currentRepo(in: cwd)
    if let here, known.isEmpty || known.contains(here) { return here }
    if known.count == 1 { return known.first! }
    throw MenuError("Couldn't tell which repo PR #\(pr) is in: pass --repo owner/name.")
}

func run(_ raw: [String]) throws {
    let args = Arguments(raw)
    let command = args.positional.first ?? "help"

    switch command {
    case "add":
        let pr = try args.number(1, "the PR number")
        guard let kind = MenuKind(rawValue: try args.at(2, "check or idea")) else {
            throw MenuError("The kind is `check` or `idea`.")
        }
        let text = try args.at(3, "the text")
        let minutes = args.options["min"].flatMap { Int($0) }
        let result = try actions.add(
            repo: try repo(for: pr, args), pr: pr, kind: kind, text: text,
            why: args.options["why"], location: args.options["where"], minutes: minutes,
            session: env["CLAUDE_CODE_SESSION_ID"], cwd: cwd
        )
        switch result {
        case .added(let item): print("added \(item.id) to #\(pr)")
        case .duplicate(let item): print("already on the menu as \(item.id) (\(item.status.label)): nothing added")
        }

    case "list":
        let file = try actions.store.read()
        if args.flags.contains("json") {
            let data = try JSONEncoder().encode(file)
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let groups = file.visibleGroups(keepSettledFor: args.flags.contains("all") ? .infinity : 12 * 3600)
        if groups.isEmpty { print("The menu is empty."); return }
        for group in groups {
            let state = group.pr.state.map { " (\($0.rawValue))" } ?? ""
            print("\(group.pr.repo)#\(group.pr.number)\(state)  \(group.pr.title ?? "")")
            group.items.forEach { print(line(for: $0)) }
        }

    case "show":
        guard let item = try actions.store.read().item(try args.at(1, "the item id")) else { throw MenuError("No such item.") }
        print(describe(item))

    case "works":
        let item = try actions.setStatus(try args.at(1, "the item id"), to: .works)
        print("\(item.id): works")
    case "later":
        let item = try actions.setStatus(try args.at(1, "the item id"), to: .later)
        print("\(item.id): later")
    case "dismiss", "no":
        let item = try actions.setStatus(try args.at(1, "the item id"), to: .dismissed)
        print("\(item.id): dismissed")

    case "delete":
        let ids = Array(args.positional.dropFirst())
        guard !ids.isEmpty else { throw MenuError("Missing the item id. See `menu help`.") }
        let removal = try actions.delete(ids)
        print("deleted \(removal.items.map(\.id).joined(separator: ", "))")

    case "reopen":
        let item = try actions.reopen(try args.at(1, "the item id"), note: args.options["note"])
        print("\(item.id) is back on the menu\(item.note.map { ": \($0)" } ?? "")")

    case "problem":
        let reported = try actions.reportProblem(try args.at(1, "the item id"), try args.at(2, "what's wrong"))
        print(reported.message)
        if let link = reported.item.link { print(link) }

    case "issue":
        let reported = try actions.makeIssue(try args.at(1, "the item id"))
        print(reported.message)
        if let link = reported.item.link { print(link) }

    case "fix":
        let number = try args.number(1, "the PR number")
        let pr = try actions.pr(number, repo: args.options["repo"])
        print(try actions.fix(pr).message)

    case "open":
        guard let item = try actions.store.read().item(try args.at(1, "the item id")) else { throw MenuError("No such item.") }
        guard let url = item.openURL else { throw MenuError("\(item.id) has no address to open: \(item.location ?? "none given").") }
        try Shell.check("open", [url.absoluteString])
        print("opened \(url.absoluteString)")

    case "refresh":
        try actions.refresh(maxAge: 0)
        print("PRs refreshed")

    case "path":
        print(actions.store.fileURL.path)

    case "hook":
        // Must never get in the agent's way: whatever happens, exit 0.
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let output = MenuHook.handle(input, actions: actions) { print(output) }

    case "help", "-h", "--help":
        print(help)

    default:
        throw MenuError("Unknown command `\(command)`. See `menu help`.")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    if CommandLine.arguments.dropFirst().first == "hook" { exit(0) }
    FileHandle.standardError.write(Data("menu: \(error.localizedDescription)\n".utf8))
    exit(1)
}
