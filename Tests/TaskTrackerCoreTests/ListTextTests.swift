import Foundation
import Testing
@testable import TaskTrackerCore

@Test func parsesTheSlackSelfChatFormat() {
    let text = """
    ```
    Done:

    Weekly reporting for the fleet
    Feedback UX

    Progress:

    Fleet Feedback Workspace:
    Let user add images to workspace agent in the prompt
    add a in-file search to the changes and files in the workspace

    Frontend core looks absolutely terrible


    Todo:

    make all slideovers resizable
    - bump fleet nuxt version to 4.6.1


    Defered

    Sandbox has no ruby?? Just npm??
    ```
    """

    #expect(ListText.parse(text) == [
        ParsedTask(status: .done, title: "Weekly reporting for the fleet"),
        ParsedTask(status: .done, title: "Feedback UX"),
        ParsedTask(status: .inProgress, title: "Let user add images to workspace agent in the prompt", folder: "Fleet Feedback Workspace"),
        ParsedTask(status: .inProgress, title: "add a in-file search to the changes and files in the workspace", folder: "Fleet Feedback Workspace"),
        ParsedTask(status: .inProgress, title: "Frontend core looks absolutely terrible"),
        ParsedTask(status: .todo, title: "make all slideovers resizable"),
        ParsedTask(status: .todo, title: "bump fleet nuxt version to 4.6.1"),
        ParsedTask(status: .deferred, title: "Sandbox has no ruby?? Just npm??"),
    ])
}

@Test func linesBeforeAnyHeaderAreTodos() {
    #expect(ListText.parse("a\n\n* [x] b") == [
        ParsedTask(status: .todo, title: "a"),
        ParsedTask(status: .todo, title: "b"),
    ])
}

@Test func formatRoundTripsWithFolders() {
    var list = TaskList()
    list.add(["doing"], to: .section(.inProgress))
    let folder = list.addFolder("Fleet", to: .inProgress)
    list.add(["one", "two"], to: .folder(folder))
    list.add(["after"], to: .section(.inProgress))
    list.add(["next", "later"], to: .section(.todo))
    list.add(["finished"], to: .section(.done))

    let text = ListText.format(list)
    #expect(text == """
    In Progress:

    doing

    Fleet:
    one
    two

    after


    Todo:

    next
    later


    Done:

    finished
    """)

    var reimported = TaskList()
    reimported.appendImported(ListText.parse(text))
    #expect(ListText.format(reimported) == text)
}

@Test func tasksWithSeveralLinesRoundTrip() {
    var list = TaskList()
    list.add(["Check the deploy\nthen ping Jörn\n  keep this indent"], to: .section(.todo))
    let folder = list.addFolder("Fleet", to: .todo)
    list.add(["Logs\nper app"], to: .folder(folder))
    list.add(["single"], to: .section(.todo))

    let text = ListText.format(list)
    #expect(text == """
    Todo:

    Check the deploy
        then ping Jörn
          keep this indent

    Fleet:
    Logs
        per app

    single
    """)

    var reimported = TaskList()
    reimported.appendImported(ListText.parse(text))
    #expect(reimported.tasks(in: .todo).map(\.title) == ["Check the deploy\nthen ping Jörn\nkeep this indent", "Logs\nper app", "single"])
}

@Test func indentedLinesOnlyContinueTheTaskRightAboveThem() {
    #expect(ListText.parse("Todo:\n\n  stray indent\nfirst\n  - sub point\n\n  after a blank line") == [
        ParsedTask(status: .todo, title: "stray indent"),
        ParsedTask(status: .todo, title: "first\nsub point"),
        ParsedTask(status: .todo, title: "after a blank line"),
    ])
}
