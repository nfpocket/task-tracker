import Foundation
import Testing
@testable import TaskTrackerCore

@MainActor
struct TaskStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TaskStoreTests-\(UUID().uuidString)")
    var fileURL: URL { directory.appending(path: "tasks.json") }

    @Test func savesEveryChangeAndReloadsIt() throws {
        let store = TaskStore(fileURL: fileURL)
        let id = try #require(store.add("Write the release notes").first)
        store.setStatus([id], to: .done)
        let folder = store.addFolder(to: .inProgress)
        store.rename(folder, to: "Fleet")
        store.add("inside", to: .folder(folder))
        store.importText("Todo:\nimported one\nDefered\nlater one")

        let reloaded = TaskStore(fileURL: fileURL)
        #expect(reloaded.problem == nil)
        // Dates are stored to the second, so compare content and ids.
        #expect(ListText.format(reloaded.list) == ListText.format(store.list))
        #expect(reloaded.list.tasks(in: .todo).map(\.id) == store.list.tasks(in: .todo).map(\.id))
        #expect(reloaded.list.tasks(in: .done).first?.completedAt != nil)
        #expect(reloaded.list.folder(folder)?.tasks.map(\.title) == ["inside"])
    }

    @Test func migratesVersion1Files() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let v1 = """
        {"version": 1, "tasks": [
          {"id": "00000000-0000-0000-0000-000000000001", "title": "done undated", "status": "done",
           "createdAt": "2026-10-15T07:17:50Z", "statusChangedAt": "2026-10-15T07:17:50Z"},
          {"id": "00000000-0000-0000-0000-000000000002", "title": "doing", "status": "inProgress",
           "createdAt": "2026-10-15T07:17:50Z", "statusChangedAt": "2026-10-15T07:17:50Z"},
          {"id": "00000000-0000-0000-0000-000000000003", "title": "done older", "status": "done",
           "createdAt": "2026-10-15T07:17:50Z", "statusChangedAt": "2026-10-15T08:00:00Z", "completedAt": "2026-10-15T08:00:00Z"},
          {"id": "00000000-0000-0000-0000-000000000004", "title": "done newer", "status": "done",
           "createdAt": "2026-10-15T07:17:50Z", "statusChangedAt": "2026-10-15T09:00:00Z", "completedAt": "2026-10-15T09:00:00Z"},
          {"id": "00000000-0000-0000-0000-000000000005", "title": "todo", "status": "todo",
           "createdAt": "2026-10-14T07:17:50Z", "statusChangedAt": "2026-10-14T07:17:50Z"}
        ]}
        """
        try Data(v1.utf8).write(to: fileURL)

        let store = TaskStore(fileURL: fileURL)
        #expect(store.problem == nil)
        #expect(store.list.tasks(in: .done).map(\.title) == ["done newer", "done older", "done undated"])
        #expect(store.list.tasks(in: .inProgress).map(\.title) == ["doing"])
        let todo = try #require(store.list.tasks(in: .todo).first)
        #expect(todo.id == UUID(uuidString: "00000000-0000-0000-0000-000000000005"))
        #expect(todo.createdAt == ISO8601DateFormatter().date(from: "2026-10-14T07:17:50Z"))

        // The original is kept, and the file itself is now version 2.
        let original = try String(contentsOf: directory.appending(path: "tasks.v1.json"), encoding: .utf8)
        #expect(original == v1)
        #expect(ListText.format(TaskStore(fileURL: fileURL).list) == ListText.format(store.list))
        #expect(try String(contentsOf: fileURL, encoding: .utf8).contains("\"version\" : 2"))
    }

    @Test func imagesAreCopiedInAndUnusedOnesCleanedUpOnLaunch() throws {
        let store = TaskStore(fileURL: fileURL)
        let ids = store.add("one\ntwo")
        let source = directory.appending(path: "Screenshot.PNG")
        try Data("png bytes".utf8).write(to: source)

        #expect(store.attachImages([.file(source), .data(Data("pasted".utf8), fileExtension: "png")], to: ids[0]) == 2)
        #expect(store.attachImages([.data(Data("other".utf8), fileExtension: "png")], to: ids[1]) == 1)
        let images = try #require(store.list.task(ids[0])?.images)
        #expect(images[0].fileName.hasSuffix(".png"))
        #expect(try Data(contentsOf: store.imageURL(images[0])) == Data("png bytes".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))

        // Removing keeps the file for undo; deleting a task does too. The next launch cleans up.
        store.removeImage(images[1].id, from: ids[0])
        let deletedTaskImage = try #require(store.list.task(ids[1])?.images.first)
        store.delete([ids[1]])
        #expect(FileManager.default.fileExists(atPath: store.imageURL(images[1]).path))

        let relaunched = TaskStore(fileURL: fileURL)
        #expect(relaunched.list.task(ids[0])?.images == [images[0]])
        #expect(FileManager.default.fileExists(atPath: relaunched.imageURL(images[0]).path))
        #expect(!FileManager.default.fileExists(atPath: relaunched.imageURL(images[1]).path))
        #expect(!FileManager.default.fileExists(atPath: relaunched.imageURL(deletedTaskImage).path))
    }

    @Test func unreadableFileLeavesImagesAlone() throws {
        let store = TaskStore(fileURL: fileURL)
        let id = try #require(store.add("task").first)
        store.attachImages([.data(Data("x".utf8), fileExtension: "png")], to: id)
        let image = try #require(store.list.task(id)?.images.first)
        try Data("garbage".utf8).write(to: fileURL)

        _ = TaskStore(fileURL: fileURL)
        #expect(FileManager.default.fileExists(atPath: store.imageURL(image).path))
    }

    @Test func filesWithoutImagesStillLoad() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        {"version": 2, "sections": [{"status": "todo", "entries": [{"task": {
          "id": "00000000-0000-0000-0000-000000000001", "title": "old task",
          "createdAt": "2026-10-15T07:17:50Z", "statusChangedAt": "2026-10-15T07:17:50Z"}}]}]}
        """.utf8).write(to: fileURL)

        let store = TaskStore(fileURL: fileURL)
        #expect(store.problem == nil)
        #expect(store.list.tasks(in: .todo).first?.images == [])
        #expect(store.list.tasks(in: .todo).first?.reminder == nil)
    }

    @Test func remindersAreSavedAndGoingOffCantBeUndone() throws {
        let store = TaskStore(fileURL: fileURL)
        let id = try #require(store.add("call back").first)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let when = Date(timeIntervalSince1970: 1_800_000_000)

        undo.beginUndoGrouping()
        store.setReminder(when, for: [id])
        undo.endUndoGrouping()
        #expect(TaskStore(fileURL: fileURL).list.task(id)?.reminder == when)

        // Going off clears it for good; undo goes back past the setting, not to the reminder.
        store.clearReminders([id])
        #expect(TaskStore(fileURL: fileURL).list.task(id)?.reminder == nil)
        #expect(undo.undoActionName == "Set Reminder")
        undo.undo()
        #expect(store.list.task(id)?.reminder == nil)
    }

    @Test func addTaskKeepsLineBreaksWhileAddSplitsLines() throws {
        let store = TaskStore(fileURL: fileURL)
        let id = try #require(store.addTask("  Fix the deploy\nthen tell Jörn  \n"))
        #expect(store.list.task(id)?.title == "Fix the deploy\nthen tell Jörn")
        #expect(store.add("one\ntwo").count == 2)
        #expect(store.addTask(" \n ") == nil)
    }

    @Test func undoAndRedoRestoreTheList() throws {
        let store = TaskStore(fileURL: fileURL)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        undo.beginUndoGrouping()
        let id = try #require(store.add("a").first)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        store.delete([id])
        undo.endUndoGrouping()
        #expect(store.list.tasks(in: .todo).isEmpty)

        undo.undo()
        #expect(store.list.task(id)?.title == "a")
        undo.redo()
        #expect(store.list.task(id) == nil)
        #expect(TaskStore(fileURL: fileURL).list.task(id) == nil)
    }

    @Test func unreadableFileIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        let store = TaskStore(fileURL: fileURL)
        #expect(store.problem != nil)
        #expect(store.list == TaskList())

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let aside = try #require(names.first { $0.hasPrefix("tasks.unreadable-") })
        #expect(try String(contentsOf: directory.appending(path: aside), encoding: .utf8) == "not json")
    }
}
