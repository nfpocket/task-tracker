import AppKit
import SwiftUI
import Testing
@testable import TaskTracker
@testable import TaskTrackerCore

/// Renders the menu section with sample items, to look at while changing it:
///
///     MENU_SNAPSHOT=/some/folder swift test --filter MenuSnapshotTests
///
/// Without MENU_SNAPSHOT it does nothing.
@MainActor
struct MenuSnapshotTests {
    @Test func rendersTheMenu() throws {
        guard let folder = ProcessInfo.processInfo.environment["MENU_SNAPSHOT"] else { return }
        let directory = FileManager.default.temporaryDirectory.appending(path: "MenuSnapshot-\(UUID().uuidString)")
        let store = MenuStore(fileURL: directory.appending(path: "menu.json"))
        let actions = MenuActions(store: store)
        let repo = "acme/web"

        try actions.registerPR(repo: repo, number: 1883, session: "s", cwd: "/tmp", info: MenuGitHub.PRInfo(
            title: "Hardening: pages paint at once, a top bar while loading", url: "https://github.com/\(repo)/pull/1883",
            state: "OPEN", headRefName: "perf/17-faster-pages"
        ))
        try actions.registerPR(repo: repo, number: 1863, session: "s", cwd: "/tmp", info: MenuGitHub.PRInfo(
            title: "Roles and rights v2, and who is here", url: "https://github.com/\(repo)/pull/1863",
            state: "MERGED", headRefName: "feat/12-roles"
        ))
        _ = try actions.add(repo: repo, pr: 1863, kind: .check, text: "Sign in with a restricted role: no edit buttons where the role can’t edit",
                            why: "Real roles on real data are what my tests couldn’t cover.", location: "Prod · the live console", minutes: 5)
        _ = try actions.add(repo: repo, pr: 1883, kind: .check, text: "Go back to a page you just left: it appears at once, without skeletons stacking up",
                            why: "You asked for revisited pages to paint at once (#1879). I could only measure it headless, not look at it.",
                            location: "Local · the #1883 branch · localhost:3000", minutes: 3)
        _ = try actions.add(repo: repo, pr: 1883, kind: .check, text: "Click into a slow page: the top bar shows progress while it loads",
                            why: "#1878.", location: "localhost:3000", minutes: 3)
        _ = try actions.add(repo: repo, pr: 1883, kind: .check, text: "Slow 4G in DevTools: icons arrive with the page, none pop in later", minutes: 5)
        _ = try actions.add(repo: repo, pr: 1883, kind: .idea, text: "The portal still loads its icons per page; the same bundle would help there",
                            why: "Noticed while bundling the console’s icons. Out of scope for #1883.")
        try store.update { file in
            file.updateItem("m3") { item in
                item.status = .problem
                item.problem = "Feedback still stacks two skeleton waves when I come back to it from Monitoring."
                item.link = "https://github.com/\(repo)/pull/1883#issuecomment-1"
            }
            file.updateItem("m4") { $0.status = .works }
        }

        let states: [(String, (MenuPanel) -> Void)] = [
            ("overview", { _ in }),
            ("check", { $0.selectedID = "m2" }),
            ("problem", { panel in
                panel.selectedID = "m2"
                panel.reportingID = "m2"
                panel.draft = "Two icons in the sidebar still pop in a moment later."
            }),
            ("idea", { $0.selectedID = "m5" }),
        ]
        for (name, setUp) in states {
            for dark in [true, false] {
                let panel = MenuPanel(actions: actions)
                panel.collapsed = false
                panel.reload()
                setUp(panel)
                try render(panel, to: URL(fileURLWithPath: folder).appending(path: "menu-\(name)-\(dark ? "dark" : "light").png"), dark: dark)
            }
        }
    }

    private func render(_ panel: MenuPanel, to url: URL, dark: Bool) throws {
        let size = CGSize(width: 420, height: 420)
        let view = VStack(spacing: 0) {
            MenuSection(panel: panel)
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))

        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        // Two passes: the scroll area takes its height from what it measured in the first.
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
