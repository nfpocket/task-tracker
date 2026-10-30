import AppKit
import Testing
@testable import TaskTracker
@testable import TaskTrackerCore

/// Applies random changes to the store and checks after each one that the outline's rows match
/// the list exactly — the animated move/insert/remove steps must never drift from the data.
@MainActor
struct OutlineSyncTests {
    @Test(arguments: [1, 2, 3, 4, 5] as [UInt64])
    func outlineFollowsRandomChanges(seed: UInt64) throws {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "collapsedItems")
        defer { UserDefaults.standard.removeObject(forKey: "collapsedItems") }

        let file = FileManager.default.temporaryDirectory.appending(path: "OutlineSyncTests-\(UUID().uuidString).json")
        let store = TaskStore(fileURL: file)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let controller = TaskOutlineController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        controller.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(controller.scrollView)

        var random = SeededRandom(seed: seed)
        for step in 0..<300 {
            let change = randomChange(store, controller, undo, &random)
            controller.sync()
            try verify(controller.outlineView, store.list, "seed \(seed), step \(step): \(change)")
        }
    }

    private func verify(_ outlineView: NSOutlineView, _ list: TaskList, _ context: String) throws {
        let rows = (0..<outlineView.numberOfRows).map { outlineView.item(atRow: $0) as! OutlineNode }
        let byKind = Dictionary(uniqueKeysWithValues: rows.map { ($0.kind, $0) })

        var expected: [OutlineNode.Kind] = []
        for section in list.sections {
            let kind = OutlineNode.Kind.section(section.status)
            expected.append(kind)
            guard let node = byKind[kind], outlineView.isItemExpanded(node) else { continue }
            for entry in section.entries {
                switch entry {
                case .task(let task):
                    expected.append(.task(task.id))
                case .folder(let folder):
                    expected.append(.folder(folder.id))
                    if let node = byKind[.folder(folder.id)], outlineView.isItemExpanded(node) {
                        expected += folder.tasks.map { .task($0.id) }
                    }
                }
            }
        }
        #expect(rows.map(\.kind) == expected, Comment(rawValue: context))
        if rows.map(\.kind) != expected { throw CancellationError() }
    }

    private func randomChange(
        _ store: TaskStore,
        _ controller: TaskOutlineController,
        _ undo: UndoManager,
        _ random: inout SeededRandom
    ) -> String {
        let list = store.list
        let statuses = TaskStatus.allCases
        let taskIDs = statuses.flatMap { list.tasks(in: $0) }.map(\.id)
        let folderIDs = statuses.flatMap { list.entries(in: $0) }.compactMap { entry -> UUID? in
            if case .folder(let folder) = entry { return folder.id }
            return nil
        }
        let containers = statuses.map(Container.section) + folderIDs.map(Container.folder)
        let anyIDs = taskIDs + folderIDs

        func someIDs(from ids: [UUID]) -> [UUID] {
            guard !ids.isEmpty else { return [] }
            return (0..<Int.random(in: 1...3, using: &random)).map { _ in ids.randomElement(using: &random)! }
        }

        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }

        switch Int.random(in: 0..<12, using: &random) {
        case 0, 1:
            let container = containers.randomElement(using: &random)!
            let index = Int.random(in: 0...list.childIDs(of: container).count, using: &random)
            store.add("task\nanother task", to: container, at: index)
            return "add to \(container) at \(index)"
        case 2:
            store.addFolder(to: statuses.randomElement(using: &random)!, at: Int.random(in: 0...3, using: &random))
            return "add folder"
        case 3, 4, 5:
            let ids = someIDs(from: anyIDs)
            let container = containers.randomElement(using: &random)!
            let index = Int.random(in: 0...list.childIDs(of: container).count, using: &random)
            store.move(ids, to: container, at: index)
            return "move \(ids.count) to \(container) at \(index)"
        case 6:
            let ids = someIDs(from: anyIDs)
            let status = statuses.randomElement(using: &random)!
            store.setStatus(ids, to: status)
            return "set status \(status)"
        case 7:
            store.delete(someIDs(from: anyIDs))
            return "delete"
        case 8:
            if let folder = folderIDs.randomElement(using: &random) { store.ungroup(folder) }
            return "ungroup"
        case 9:
            store.groupIntoNewFolder(someIDs(from: taskIDs))
            return "group"
        case 10:
            let outlineView = controller.outlineView
            guard outlineView.numberOfRows > 0 else { return "nothing to toggle" }
            let node = outlineView.item(atRow: Int.random(in: 0..<outlineView.numberOfRows, using: &random)) as! OutlineNode
            guard node.expansionKey != nil else { return "toggle a task (nothing)" }
            if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) } else { outlineView.expandItem(node) }
            return "toggle \(node.kind)"
        default:
            undo.endUndoGrouping()
            if undo.canUndo { undo.undo() }
            undo.beginUndoGrouping()
            return "undo"
        }
    }
}

/// SplitMix64, so failures reproduce.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
