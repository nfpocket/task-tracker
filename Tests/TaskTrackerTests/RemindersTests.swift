import AppKit
import Testing
@testable import TaskTracker
@testable import TaskTrackerCore

@MainActor
struct RemindersTests {
    let t0 = Date.now.addingTimeInterval(3600)

    func makeStore() -> TaskStore {
        TaskStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "RemindersTests-\(UUID().uuidString)/tasks.json"))
    }

    /// Without notifications, a due reminder opens the list at the task. Each goes off once and is cleared.
    @Test func dueRemindersGoOffOnceAndAreCleared() throws {
        let store = makeStore()
        let ids = store.add("call back\nwrite up\nlater")
        store.setReminder(t0.addingTimeInterval(60), for: [ids[0]])
        store.setReminder(t0.addingTimeInterval(30), for: [ids[1]])
        store.setReminder(t0.addingTimeInterval(600), for: [ids[2]])

        let reminders = Reminders(store: store, center: nil)
        var shown: [UUID] = []
        reminders.showTask = { shown.append($0) }
        reminders.now = { t0 }
        reminders.check()
        #expect(shown.isEmpty)
        #expect(reminders.nextCheck == t0.addingTimeInterval(30))

        reminders.now = { t0.addingTimeInterval(90) }
        reminders.check()
        // Both went off; the list opens at the earlier one.
        #expect(shown == [ids[1]])
        #expect(store.list.task(ids[0])?.reminder == nil)
        #expect(store.list.task(ids[1])?.reminder == nil)
        #expect(reminders.nextCheck == t0.addingTimeInterval(600))

        reminders.check()
        #expect(shown == [ids[1]])
    }

    /// Undo can bring back a reminder that already went off. It's cleared again, not repeated.
    @Test func undoDoesntRepeatAReminder() throws {
        let store = makeStore()
        let id = try #require(store.add("call back").first)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        store.setReminder(t0, for: [id])
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        store.rename(id, to: "call back Jörn")
        undo.endUndoGrouping()

        let reminders = Reminders(store: store, center: nil)
        var shown: [UUID] = []
        reminders.showTask = { shown.append($0) }
        reminders.now = { t0 }
        reminders.check()
        #expect(shown == [id])

        undo.undo()
        #expect(store.list.task(id)?.reminder == t0)
        reminders.now = { t0.addingTimeInterval(5) }
        reminders.check()
        #expect(shown == [id])
        #expect(store.list.task(id)?.reminder == nil)
    }

    /// Reminders that came due while the app wasn't running go off at launch.
    @Test func missedRemindersGoOffAtStart() throws {
        let store = makeStore()
        let id = try #require(store.add("call back").first)
        store.setReminder(.now.addingTimeInterval(-3600), for: [id])

        let reminders = Reminders(store: store, center: nil)
        var shown: [UUID] = []
        reminders.showTask = { shown.append($0) }
        reminders.start()
        #expect(shown == [id])
        #expect(store.list.task(id)?.reminder == nil)
    }

    @Test func promptReadsTypedTextAndThePicker() {
        let prompt = ReminderPrompt(about: "call back", current: nil)
        #expect(prompt.date == prompt.picker.dateValue)
        #expect(prompt.alert.buttons[0].isEnabled)

        func type(_ text: String) {
            prompt.field.stringValue = text
            prompt.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: prompt.field))
        }
        type("in 2 hours")
        let date = prompt.date
        #expect(date.map { abs($0.timeIntervalSinceNow - 7200) < 5 } == true)
        #expect(prompt.picker.dateValue == date)

        type("whenever")
        #expect(prompt.date == nil)
        #expect(!prompt.alert.buttons[0].isEnabled)
        #expect(prompt.hint.stringValue.hasPrefix("Try"))

        type("2020-01-01 10:00")
        #expect(prompt.date == nil)
        #expect(prompt.hint.stringValue == "That's in the past")

        type("")
        #expect(prompt.date == prompt.picker.dateValue)
        #expect(prompt.alert.buttons[0].isEnabled)
    }
}
