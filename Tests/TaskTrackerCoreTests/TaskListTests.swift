import Foundation
import Testing
@testable import TaskTrackerCore

private let t0 = Date(timeIntervalSince1970: 1_791_000_000)
private let t1 = t0.addingTimeInterval(60)

/// The list as nested titles: loose tasks as "title", folders as "Folder[a, b]".
private func outline(_ list: TaskList, _ status: TaskStatus) -> [String] {
    list.entries(in: status).map { entry in
        switch entry {
        case .task(let task): task.title
        case .folder(let folder): "\(folder.title)[\(folder.tasks.map(\.title).joined(separator: ", "))]"
        }
    }
}

@Test func addGoesToTheBottomOrTheTopOfDone() {
    var list = TaskList()
    list.add(["a"], now: t0)
    list.add(["  b  ", "", "c"], now: t0)
    list.add(["old"], to: .section(.done), now: t0)
    list.add(["new"], to: .section(.done), now: t1)

    #expect(outline(list, .todo) == ["a", "b", "c"])
    #expect(outline(list, .done) == ["new", "old"])
    #expect(list.task(list.childIDs(of: .section(.done))[0])?.completedAt == t1)
    #expect(list.tasks(in: .todo).allSatisfy { $0.createdAt == t0 && $0.completedAt == nil })
}

@Test func addIntoAFolderAtAnIndexKeepsOrder() {
    var list = TaskList()
    let folder = list.addFolder("Fleet", to: .inProgress)
    list.add(["a", "d"], to: .folder(folder))
    list.add(["b", "c"], to: .folder(folder), at: 1)

    #expect(outline(list, .inProgress) == ["Fleet[a, b, c, d]"])
}

@Test func moveIndexCountsTheMovedItemsWhereTheyAre() {
    // Like dragging "a" to between "c" and "d": NSOutlineView proposes index 3.
    var list = TaskList()
    let ids = list.add(["a", "b", "c", "d"])
    list.move([ids[0]], to: .section(.todo), at: 3)
    #expect(outline(list, .todo) == ["b", "c", "a", "d"])

    list.move([ids[3], ids[1]], to: .section(.todo), at: 0)
    #expect(outline(list, .todo) == ["d", "b", "c", "a"])

    list.move([ids[0]], to: .section(.todo), at: 4)
    #expect(outline(list, .todo) == ["d", "b", "c", "a"])
}

@Test func movingAcrossSectionsStampsTimes() {
    var list = TaskList()
    let id = list.add(["task"], now: t0)[0]

    list.move([id], to: .section(.todo), at: 0, now: t1)
    #expect(list.task(id)?.statusChangedAt == t0)

    list.move([id], to: .section(.done), now: t1)
    #expect(list.task(id)?.statusChangedAt == t1)
    #expect(list.task(id)?.completedAt == t1)
    #expect(list.task(id)?.createdAt == t0)

    list.move([id], to: .section(.deferred), now: t1)
    #expect(list.task(id)?.completedAt == nil)
}

@Test func tasksMoveIntoAndOutOfFolders() {
    var list = TaskList()
    let ids = list.add(["a", "b"], now: t0)
    let folder = list.addFolder("Fleet", to: .inProgress)

    list.move([ids[1], ids[0]], to: .folder(folder), now: t1)
    #expect(outline(list, .inProgress) == ["Fleet[b, a]"])
    #expect(outline(list, .todo) == [])
    #expect(list.status(of: ids[0]) == .inProgress)
    #expect(list.task(ids[0])?.statusChangedAt == t1)
    #expect(list.container(of: ids[0]) == .folder(folder))

    list.move([ids[0]], to: .section(.inProgress), at: 0)
    #expect(outline(list, .inProgress) == ["a", "Fleet[b]"])
}

@Test func foldersDontNest() {
    var list = TaskList()
    let first = list.addFolder("First", to: .todo)
    let second = list.addFolder("Second", to: .todo)
    list.add(["x"])

    list.move([second], to: .folder(first), at: 0)
    #expect(outline(list, .todo) == ["First[]", "Second[]", "x"])
    list.move([first], to: .folder(second))
    #expect(outline(list, .todo) == ["Second[]", "First[]", "x"])
}

@Test func movingAFolderCarriesItsTasksAndMergesByName() {
    var list = TaskList()
    let doing = list.addFolder("Fleet", to: .inProgress, now: t0)
    let tasks = list.add(["a", "b"], to: .folder(doing), now: t0)
    let done = list.addFolder("fleet ", to: .done, now: t0)
    list.add(["old"], to: .folder(done), now: t0)

    list.move([doing, tasks[0]], to: .section(.done), at: 0, now: t1)

    #expect(outline(list, .inProgress) == [])
    #expect(outline(list, .done) == ["fleet[a, b, old]"])
    #expect(list.task(tasks[1])?.completedAt == t1)
}

@Test func completingATaskKeepsItsFolder() {
    var list = TaskList()
    list.add(["loose done"], to: .section(.done), now: t0)
    let folder = list.addFolder("Fleet Workspace", to: .inProgress)
    let ids = list.add(["a", "b", "c"], to: .folder(folder))

    list.setStatus([ids[0]], to: .done, now: t1)
    #expect(outline(list, .done) == ["Fleet Workspace[a]", "loose done"])

    list.setStatus([ids[1], ids[2]], to: .done, now: t1)
    #expect(outline(list, .done) == ["Fleet Workspace[b, c, a]", "loose done"])
    #expect(outline(list, .inProgress) == ["Fleet Workspace[]"])

    list.setStatus([ids[2]], to: .todo, now: t1)
    #expect(outline(list, .todo) == ["Fleet Workspace[c]"])
    #expect(list.task(ids[2])?.completedAt == nil)
}

@Test func settingAFolderStatusMovesTheWholeFolder() {
    var list = TaskList()
    list.add(["first"], to: .section(.done))
    let folder = list.addFolder("Fleet", to: .inProgress)
    list.add(["a", "b"], to: .folder(folder))

    list.setStatus([folder], to: .done, now: t1)
    #expect(outline(list, .done) == ["Fleet[a, b]", "first"])
    #expect(list.tasks(in: .done).allSatisfy { $0.completedAt != nil })
}

@Test func groupingAndUngrouping() {
    var list = TaskList()
    let ids = list.add(["a", "b", "c", "d"])

    let folder = list.groupIntoNewFolder([ids[2], ids[1]], title: "Group")
    #expect(outline(list, .todo) == ["a", "Group[c, b]", "d"])

    list.ungroup(try! #require(folder))
    #expect(outline(list, .todo) == ["a", "c", "b", "d"])
}

@Test func renameAndDelete() {
    var list = TaskList()
    let folder = list.addFolder("Folder", to: .todo)
    let inside = list.add(["inside"], to: .folder(folder))[0]
    let loose = list.add(["loose"])[0]

    list.rename(inside, to: " renamed ")
    list.rename(folder, to: "Group")
    list.rename(loose, to: "   ")
    #expect(outline(list, .todo) == ["Group[renamed]", "loose"])

    list.delete([folder])
    #expect(outline(list, .todo) == ["loose"])
    #expect(list.task(inside) == nil)
}

@Test func importedTasksJoinFoldersByName() {
    var list = TaskList()
    list.appendImported([
        ParsedTask(status: .inProgress, title: "a", folder: "Fleet"),
        ParsedTask(status: .inProgress, title: "loose"),
        ParsedTask(status: .inProgress, title: "b", folder: "fleet"),
        ParsedTask(status: .done, title: "shipped"),
    ], now: t0)

    #expect(outline(list, .inProgress) == ["Fleet[a, b]", "loose"])
    #expect(list.tasks(in: .done).first?.completedAt == nil)
}

@Test func linksAndImagesAttachToTasksAnywhere() {
    var list = TaskList()
    let folder = list.addFolder("Fleet", to: .inProgress)
    let task = list.add(["Fix the viewer"], to: .folder(folder))[0]
    let url = URL(string: "https://github.com/acme/app/pull/2")!

    list.appendLink(url, to: task)
    list.appendLink(url, to: task)
    #expect(list.task(task)?.title == "Fix the viewer https://github.com/acme/app/pull/2")

    let first = ImageAttachment(fileName: "a.png")
    let second = ImageAttachment(fileName: "b.png")
    list.addImages([first, second], to: task)
    list.removeImage(first.id, from: task)
    #expect(list.task(task)?.images == [second])

    // Images travel with their task.
    list.setStatus([task], to: .done)
    #expect(list.task(task)?.images == [second])
    #expect(list.allImages == [second])
}

@Test func remindersAreSetClearedAndDroppedWhenDone() {
    var list = TaskList()
    let ids = list.add(["a", "b", "c"], now: t0)
    let folder = list.groupIntoNewFolder([ids[2]], now: t0)!
    list.setReminder(t1, for: [ids[0], ids[2], folder])
    list.setReminder(t0, for: [ids[1]])

    #expect(list.tasksWithReminders.map(\.title) == ["b", "a", "c"])
    list.setReminder(nil, for: [ids[1]])
    #expect(list.task(ids[1])?.reminder == nil)

    // A finished task needs no reminding, and doesn't get one while done.
    list.setStatus([ids[2]], to: .done, now: t1)
    #expect(list.task(ids[2])?.reminder == nil)
    list.setReminder(t1, for: [ids[2]])
    #expect(list.task(ids[2])?.reminder == nil)
    #expect(list.tasksWithReminders.map(\.title) == ["a"])

    // Moving between other sections keeps it.
    list.setStatus([ids[0]], to: .inProgress, now: t1)
    #expect(list.task(ids[0])?.reminder == t1)
}
