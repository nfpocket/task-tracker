import Foundation
import Testing
@testable import TaskTrackerCore

struct MenuTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MenuTests-\(UUID().uuidString)")
    var store: MenuStore { MenuStore(fileURL: directory.appending(path: "menu.json")) }
    let repo = "acme/web"

    @Test func addsItemsAndSkipsTheSameTextTwice() throws {
        let actions = MenuActions(store: store)
        let first = try actions.add(repo: repo, pr: 1883, kind: .check, text: "Go back to a page: it appears at once",
                                    why: "headless only", location: "localhost:3000", minutes: 3, session: "s1", cwd: "/tmp")
        guard case .added(let item) = first else { Issue.record("not added"); return }
        #expect(item.id == "m1")
        #expect(item.status == .open)

        let again = try actions.add(repo: repo, pr: 1890, kind: .check, text: "  go back to a page:   it appears at once ")
        guard case .duplicate(let existing) = again else { Issue.record("added twice"); return }
        #expect(existing.id == item.id)

        let file = try store.read()
        #expect(file.items.count == 1)
        #expect(file.pr(repo, 1883)?.session == "s1")
        #expect(file.pr(repo, 1883)?.cwd == "/tmp")
    }

    @Test func aDismissedIdeaIsNotProposedAgain() throws {
        let actions = MenuActions(store: store)
        guard case .added(let idea) = try actions.add(repo: repo, pr: 1, kind: .idea, text: "Bundle the portal icons") else { return }
        try actions.setStatus(idea.id, to: .dismissed)
        #expect(try actions.add(repo: repo, pr: 2, kind: .idea, text: "Bundle the portal icons") != .added(idea))
        #expect(try store.read().items.count == 1)
    }

    @Test func theHookSessionWinsOverTheOneThatAddsItems() throws {
        let actions = MenuActions(store: store)
        try actions.registerPR(repo: repo, number: 5, session: "builder", cwd: "/work", info: nil)
        _ = try actions.add(repo: repo, pr: 5, kind: .check, text: "x", session: "someone-else", cwd: "/elsewhere")
        let pr = try #require(try store.read().pr(repo, 5))
        #expect(pr.session == "builder")
        #expect(pr.cwd == "/work")
    }

    @Test func reopenPutsAFixedCheckBack() throws {
        let actions = MenuActions(store: store)
        guard case .added(let item) = try actions.add(repo: repo, pr: 1, kind: .check, text: "x") else { return }
        try actions.setStatus(item.id, to: .fixing)
        let reopened = try actions.reopen(item.id, note: "fixed in 4e1a2b")
        #expect(reopened.status == .open)
        #expect(reopened.note == "fixed in 4e1a2b")
    }

    @Test func deletesForGoodAndRestoresInPlace() throws {
        let actions = MenuActions(store: store)
        _ = try actions.add(repo: repo, pr: 1, kind: .check, text: "first")
        _ = try actions.add(repo: repo, pr: 1, kind: .check, text: "second")
        _ = try actions.add(repo: repo, pr: 2, kind: .idea, text: "only one on PR 2")

        let removal = try actions.delete(["m1", "m3"])
        #expect(removal.items.map(\.id) == ["m1", "m3"])
        // PR 2 had nothing else on it, so it goes too; PR 1 keeps m2.
        #expect(removal.prs.map(\.number) == [2])
        var file = try store.read()
        #expect(file.items.map(\.id) == ["m2"])
        #expect(file.prs.map(\.number) == [1])
        // Unlike dismissing, a deleted text may be proposed again.
        guard case .added = try actions.add(repo: repo, pr: 2, kind: .idea, text: "only one on PR 2") else {
            Issue.record("a deleted item blocked the same text"); return
        }
        _ = try actions.delete(["m4"])

        try actions.restore(removal)
        file = try store.read()
        #expect(file.visibleGroups().first { $0.pr.number == 1 }?.items.map(\.id) == ["m1", "m2"])
        #expect(file.pr(repo, 2) != nil)
        #expect(throws: MenuError.self) { try actions.delete(["m99"]) }
    }

    @Test func showsOpenItemsAndRecentlySettledOnes() {
        var file = MenuFile()
        let old = Date.now.addingTimeInterval(-24 * 3600)
        _ = file.add(repo: repo, pr: 1, kind: .idea, text: "an idea", now: old)
        _ = file.add(repo: repo, pr: 1, kind: .check, text: "a check", now: old)
        _ = file.add(repo: repo, pr: 2, kind: .check, text: "settled long ago", now: old)
        _ = file.add(repo: repo, pr: 2, kind: .check, text: "settled just now", now: old)
        file.updateItem("m3", now: old) { $0.status = .works }
        file.updateItem("m4") { $0.status = .works }

        let groups = file.visibleGroups()
        // The PR with the newest item comes first.
        #expect(groups.map(\.pr.number) == [2, 1])
        let first = groups.first { $0.pr.number == 1 }!
        // Checks come before ideas.
        #expect(first.items.map(\.text) == ["a check", "an idea"])
        let second = groups.first { $0.pr.number == 2 }!
        #expect(second.items.map(\.text) == ["settled just now"])
        #expect(file.openChecks == 1)
        #expect(file.openIdeas == 1)
    }

    @Test func findsTheAddressToOpen() {
        func item(_ location: String?) -> MenuItem {
            MenuItem(id: "m1", repo: repo, pr: 1, kind: .check, text: "x", location: location, status: .open,
                     createdAt: .now, updatedAt: .now)
        }
        #expect(item("Local · the #1883 branch · localhost:3000").openURL?.absoluteString == "http://localhost:3000")
        #expect(item("https://example.com/apps/42, as an admin").openURL?.absoluteString == "https://example.com/apps/42")
        #expect(item("prod").openURL == nil)
        #expect(item(nil).openURL == nil)
    }

    @Test func readsReposAndPullRequests() {
        #expect(MenuGitHub.repo(fromRemote: "https://github.com/acme/web.git") == repo)
        #expect(MenuGitHub.repo(fromRemote: "git@github.com:acme/web.git\n") == repo)
        #expect(MenuGitHub.repo(fromRemote: "https://github.com/nfpocket/task-tracker") == "nfpocket/task-tracker")
        let printed = "Creating pull request for perf/17-faster-pages into staging\n\nhttps://github.com/acme/web/pull/1883\n"
        let found = MenuGitHub.pullRequest(in: printed)
        #expect(found?.repo == repo)
        #expect(found?.number == 1883)
        #expect(MenuGitHub.pullRequest(in: "no address here") == nil)
    }

    @Test func theHookActsOnlyOnACreatedPR() throws {
        let actions = MenuActions(store: store)
        func event(_ command: String, _ stdout: String) -> Data {
            let object: [String: Any] = [
                "session_id": "abc", "cwd": "/work", "hook_event_name": "PostToolUse", "tool_name": "Bash",
                "tool_input": ["command": command], "tool_response": ["stdout": stdout, "stderr": ""],
            ]
            return try! JSONSerialization.data(withJSONObject: object)
        }

        #expect(MenuHook.handle(event("ls", "https://github.com/a/b/pull/1"), actions: actions, lookUpPR: false) == nil)
        #expect(MenuHook.handle(event("gh pr create --fill", "nothing"), actions: actions, lookUpPR: false) == nil)
        #expect(MenuHook.handle(Data("not json".utf8), actions: actions, lookUpPR: false) == nil)

        let output = try #require(MenuHook.handle(
            event("gh pr create --base staging --title t --body b", "https://github.com/\(repo)/pull/1883\n"),
            actions: actions, lookUpPR: false
        ))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let specific = try #require(json["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PostToolUse")
        #expect((specific["additionalContext"] as? String)?.contains("menu add 1883 check") == true)
        #expect(try store.read().pr(repo, 1883)?.session == "abc")
    }

    @Test func theFixPromptListsEveryProblem() {
        let pr = MenuPR(repo: repo, number: 1883)
        var item = MenuItem(id: "m3", repo: repo, pr: 1883, kind: .check, text: "Go back to a page", status: .problem,
                            createdAt: .now, updatedAt: .now)
        item.problem = "Feedback still stacks two skeleton waves\nwhen I come back."
        let prompt = MenuFix.prompt(pr: pr, problems: [item])
        #expect(prompt.contains("PR #1883"))
        #expect(prompt.contains("- m3: Go back to a page"))
        #expect(prompt.contains("Problem: Feedback still stacks two skeleton waves when I come back."))
        #expect(prompt.contains("menu reopen <id>"))
        #expect(MenuFix.shellQuoted("it's") == #"'it'\''s'"#)
    }

    @Test func shortensIssueTitlesAtAWord() {
        #expect(MenuGitHub.shortened("short", to: 10) == "short")
        #expect(MenuGitHub.shortened("The portal still loads its icons per page", to: 20) == "The portal still…")
    }
}
