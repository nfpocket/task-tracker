import AppKit
import TaskTrackerCore
import UserNotifications

/// Sets off reminders when they come due: a notification for each task, then the reminder is
/// cleared. Clicking the notification opens the list at the task. Without notifications (turned
/// off, or a debug build with no app bundle) the list opens at the task by itself instead.
@MainActor
final class Reminders: NSObject {
    /// Opens the list at a task.
    var showTask: (UUID) -> Void = { _ in }
    /// Tests set the clock.
    var now: () -> Date = { .now }

    private let store: TaskStore
    private let center: UNUserNotificationCenter?
    private var timer: Timer?
    /// Reminders up to here have gone off. Undo can bring back one that already went off; it
    /// isn't repeated, only cleared again.
    private var checkedUntil = Date.distantPast
    private var askedForPermission = false

    nonisolated private static let taskIDKey = "taskID"

    /// Notifications need an app bundle, which a plain `swift build` binary doesn't have.
    static var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    init(store: TaskStore, center: UNUserNotificationCenter?) {
        self.store = store
        self.center = center
        super.init()
    }

    /// When the next reminder goes off.
    var nextCheck: Date? { timer?.fireDate }

    /// Starts watching the store. Reminders that came due while the app wasn't running go off now.
    func start() {
        center?.delegate = self
        // Timers don't count time asleep, and the clock can be changed.
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        _ = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        observeStore()
        check()
    }

    /// Sets off every reminder that's due and waits for the next one.
    func check() {
        let now = now()
        let due = store.list.tasksWithReminders.filter { $0.reminder! <= now }
        let fresh = due.filter { $0.reminder! > checkedUntil }
        checkedUntil = now
        if !due.isEmpty { store.clearReminders(due.map(\.id)) }
        if !fresh.isEmpty { remind(fresh) }
        scheduleNext()
    }

    private func observeStore() {
        withObservationTracking {
            _ = store.list
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.check()
                self?.observeStore()
            }
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        timer = nil
        guard let next = store.list.tasksWithReminders.first?.reminder else { return }
        askForPermission()
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Asked once there's a reminder to deliver, not at launch.
    private func askForPermission() {
        guard let center, !askedForPermission else { return }
        askedForPermission = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func remind(_ tasks: [TaskItem]) {
        guard let center else { return remindInList(tasks) }
        Task {
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return remindInList(tasks) }
            for task in tasks {
                let content = UNMutableNotificationContent()
                content.title = "Reminder"
                content.body = task.title
                content.sound = .default
                content.userInfo = [Self.taskIDKey: task.id.uuidString]
                // One per task: a later reminder for the same task replaces the earlier one.
                try? await center.add(UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil))
            }
        }
    }

    private func remindInList(_ tasks: [TaskItem]) {
        NSSound.beep()
        if let first = tasks.first { showTask(first.id) }
    }
}

extension Reminders: UNUserNotificationCenterDelegate {
    /// Shows reminders while the list is open, too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let id = (userInfo[Self.taskIDKey] as? String).flatMap(UUID.init(uuidString:)) else { return }
        await MainActor.run { showTask(id) }
    }
}
