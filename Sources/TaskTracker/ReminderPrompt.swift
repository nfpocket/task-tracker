import AppKit
import TaskTrackerCore

/// Asks when to be reminded. Type a time from now ("in 30 minutes", "2h") or a date and time
/// ("14:30", "tomorrow 9:00"), or set one in the date picker; typing moves the picker along.
@MainActor
final class ReminderPrompt: NSObject, NSTextFieldDelegate {
    let alert = NSAlert()
    let field = NSTextField()
    let picker = NSDatePicker()
    let hint = NSTextField(labelWithString: "")
    /// What the reminder would be set to, if it can be set.
    private(set) var date: Date?

    /// Shows the prompt about a task (or "3 tasks") and returns the chosen date, or nil when cancelled.
    static func run(about subject: String, current: Date?) -> Date? {
        ReminderPrompt(about: subject, current: current).run()
    }

    init(about subject: String, current: Date?) {
        super.init()
        alert.messageText = "Remind Me"
        alert.informativeText = subject
        alert.addButton(withTitle: "Set Reminder")
        alert.addButton(withTitle: "Cancel")

        field.placeholderString = "in 30 minutes, 2h, 14:30, tomorrow 9:00"
        field.delegate = self
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.minDate = .now
        picker.dateValue = current ?? Self.inAboutAnHour()
        picker.target = self
        picker.action = #selector(pickerChanged)

        let stack = NSStackView(views: [field, hint, picker])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        use(picker.dateValue)
    }

    private func run() -> Date? {
        alert.runModal() == .alertFirstButtonReturn ? date : nil
    }

    func controlTextDidChange(_ notification: Notification) {
        let text = field.stringValue
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            use(picker.dateValue)
        } else if let date = ReminderText.date(from: text) {
            // The picker keeps the last usable date, for when the text is cleared again.
            if date > .now { picker.dateValue = date }
            use(date)
        } else {
            use(nil)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if date == nil { NSSound.beep() } else { alert.buttons[0].performClick(nil) }
        return true
    }

    @objc private func pickerChanged() {
        field.stringValue = ""
        use(picker.dateValue)
    }

    private func use(_ date: Date?) {
        let now = Date.now
        self.date = date.flatMap { $0 > now ? $0 : nil }
        hint.stringValue = switch date {
        case nil:
            "Try “in 30 minutes”, “2h”, “14:30” or “tomorrow 9:00”"
        case let date? where date <= now:
            "That's in the past"
        case let date?:
            date.formatted(.dateTime.weekday(.wide).day().month().hour().minute())
                + " · " + date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
        }
        alert.buttons.first?.isEnabled = self.date != nil
    }

    /// An hour from now, rounded up to five minutes.
    private static func inAboutAnHour() -> Date {
        let seconds = Date.now.addingTimeInterval(3600).timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 300).rounded(.up) * 300)
    }
}
