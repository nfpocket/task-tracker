import AppKit
import Testing
@testable import TaskTracker
@testable import TaskTrackerCore

/// ⌘Return starts a new line in a task, both in the add field and while renaming.
@MainActor
struct MultiLineTests {
    let store: TaskStore
    let controller: TaskOutlineController
    let window: NSWindow

    init() {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "collapsedItems")
        store = TaskStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "MultiLineTests-\(UUID().uuidString)/tasks.json"))
        controller = TaskOutlineController(store: store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        controller.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(controller.scrollView)
        window.contentView!.layoutSubtreeIfNeeded()
    }

    private func row(of id: UUID) -> Int {
        (0..<controller.outlineView.numberOfRows).first { (controller.outlineView.item(atRow: $0) as? OutlineNode)?.id == id } ?? -1
    }

    @Test func lineBreakWhileRenamingATask() throws {
        let id = try #require(store.addTask("Check the deploy"))
        controller.sync()
        controller.rename(id)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.moveToEndOfDocument(nil)
        let oneLine = controller.outlineView.rect(ofRow: row(of: id)).height

        #expect(controller.insertLineBreakIfNeeded(firstResponder: editor))
        editor.insertText("then tell Jörn", replacementRange: editor.selectedRange())
        #expect(controller.outlineView.rect(ofRow: row(of: id)).height > oneLine, "the row grows while typing")

        window.makeFirstResponder(controller.outlineView) // what Return does: commit
        #expect(store.list.task(id)?.title == "Check the deploy\nthen tell Jörn")
    }

    @Test func folderNamesStayOnOneLine() throws {
        let folder = store.addFolder(to: .todo)
        controller.sync()
        controller.rename(folder)
        #expect(!controller.insertLineBreakIfNeeded(firstResponder: window.firstResponder))
    }

    @Test func lineBreakInTheAddFieldMakesOneTask() throws {
        let field = NSTextField(string: "")
        window.contentView!.addSubview(field)
        window.makeFirstResponder(field)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("Fix the viewer", replacementRange: editor.selectedRange())
        #expect(controller.insertLineBreakIfNeeded(firstResponder: editor))
        editor.insertText("see the screenshot", replacementRange: editor.selectedRange())

        let id = try #require(controller.addFromField(field.stringValue))
        #expect(store.list.task(id)?.title == "Fix the viewer\nsee the screenshot")
        #expect(store.list.tasks(in: .todo).count == 1)
    }

    @Test func theListIgnoresCommandReturn() {
        window.makeFirstResponder(controller.outlineView)
        #expect(!controller.insertLineBreakIfNeeded(firstResponder: window.firstResponder))
    }
}
