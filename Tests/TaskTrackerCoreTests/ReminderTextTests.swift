import Foundation
import Testing
@testable import TaskTrackerCore

struct ReminderTextTests {
    let calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    /// Tue 27 Oct 2026, 09:20 in Berlin.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9, minute: 20))! }

    func parse(_ text: String) -> Date? {
        ReminderText.date(from: text, now: now, calendar: calendar)
    }

    func at(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test(arguments: [
        ("in 30 minutes", 30 * 60),
        ("30 min", 30 * 60),
        ("30m", 30 * 60),
        ("  In 2 Hours ", 2 * 3600),
        ("2h", 2 * 3600),
        ("1h 30m", 90 * 60),
        ("1h30m", 90 * 60),
        ("1 hour and 15 minutes", 75 * 60),
        ("1.5h", 90 * 60),
        ("1,5 Stunden", 90 * 60),
        ("in an hour", 3600),
        ("in 10 Minuten", 10 * 60),
        ("in 2 days", 2 * 86400),
        ("3 Tagen", 3 * 86400),
        ("1w", 7 * 86400),
    ] as [(String, Int)])
    func readsTimeFromNow(text: String, seconds: Int) {
        #expect(parse(text) == now.addingTimeInterval(TimeInterval(seconds)))
    }

    @Test func readsTimesOfDayAsTheirNextOccurrence() {
        #expect(parse("14:30") == at(day: 27, 14, 30))
        #expect(parse("at 14.30") == at(day: 27, 14, 30))
        #expect(parse("9:00") == at(day: 28, 9))
        #expect(parse("9:20") == at(day: 28, 9, 20))
        #expect(parse("9:21") == at(day: 27, 9, 21))
        #expect(parse("9am") == at(day: 28, 9))
        #expect(parse("9:30 pm") == at(day: 27, 21, 30))
        #expect(parse("12am") == at(day: 28, 0))
        #expect(parse("21 Uhr") == at(day: 27, 21))
        #expect(parse("um 0:15") == at(day: 28, 0, 15))
    }

    @Test(arguments: ["", "30", "soon", "in", "m", "2 2h", "h2", "25:00", "9:5", "in 30 minutes please", "-5m", "5m!"])
    func rejectsWhatItCantRead(text: String) {
        #expect(parse(text) == nil)
    }

    /// Written-out dates go to the system's date detector, which reads them relative to the real clock.
    @Test func readsWrittenOutDates() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        let expected = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        #expect(ReminderText.date(from: "tomorrow 9:00") == expected)
        #expect(ReminderText.date(from: "Tomorrow at 9am") == expected)
        #expect(ReminderText.date(from: "2026-10-28 14:00") == Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 14)))
    }
}
