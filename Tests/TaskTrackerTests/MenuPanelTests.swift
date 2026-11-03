import Foundation
import Testing
@testable import TaskTracker
@testable import TaskTrackerCore

@MainActor
struct MenuPanelTests {
    let store = MenuStore(fileURL: FileManager.default.temporaryDirectory
        .appending(path: "MenuPanelTests-\(UUID().uuidString)/menu.json"))

    private func makePanel() throws -> (MenuPanel, UndoManager) {
        let actions = MenuActions(store: store)
        _ = try actions.add(repo: "acme/web", pr: 7, kind: .check, text: "Open the page: it loads")
        _ = try actions.add(repo: "acme/web", pr: 7, kind: .idea, text: "Cache the page")
        let panel = MenuPanel(actions: actions)
        let undo = UndoManager()
        undo.groupsByEvent = false
        panel.undoManager = undo
        panel.reload()
        return (panel, undo)
    }

    private func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func undoTakesBackAStatusChange() throws {
        let (panel, undo) = try makePanel()
        step(undo) { panel.setStatus(panel.file.item("m1")!, .works) }
        #expect(try store.read().item("m1")?.status == .works)
        #expect(undo.undoActionName == "Works")

        undo.undo()
        #expect(try store.read().item("m1")?.status == .open)
        undo.redo()
        #expect(try store.read().item("m1")?.status == .works)
    }

    @Test func undoBringsBackADeletedItem() throws {
        let (panel, undo) = try makePanel()
        panel.selectedID = "m2"
        step(undo) { panel.delete([panel.file.item("m2")!]) }
        #expect(try store.read().item("m2") == nil)
        #expect(panel.selectedID == nil)

        undo.undo()
        #expect(try store.read().item("m2")?.text == "Cache the page")
        undo.redo()
        #expect(try store.read().item("m2") == nil)
    }

    @Test func deletingAWholePRTakesItsItemsAndCanComeBack() throws {
        let (panel, undo) = try makePanel()
        let group = try #require(panel.groups.first)
        step(undo) { panel.delete(group.items) }
        #expect(try store.read().items.isEmpty)
        #expect(try store.read().prs.isEmpty)

        undo.undo()
        #expect(try store.read().items.map(\.id).sorted() == ["m1", "m2"])
        #expect(try store.read().pr("acme/web", 7) != nil)
    }
}
