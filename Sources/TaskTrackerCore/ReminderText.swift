import Foundation

/// Reads when to be reminded from what the user typed: a span of time from now ("in 30 minutes",
/// "2h", "1h 30m", "in 3 Tagen"), a time of day ("14:30", "9am", "21 Uhr") or a date and time
/// ("tomorrow 9:00", "friday 10am", "28.10. 14:00").
public enum ReminderText {
    /// The date meant, or nil if the text can't be read. A time of day means its next
    /// occurrence; a date written out in full can be in the past.
    public static func date(from text: String, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let span = timeSpan(text) { return now.addingTimeInterval(span) }
        if let time = timeOfDay(text) {
            return calendar.nextDate(after: now, matching: time, matchingPolicy: .nextTime)
        }
        return detectedDate(text)
    }

    private static let secondsPerUnit: [String: TimeInterval] = {
        var table: [String: TimeInterval] = [:]
        for (seconds, names) in [
            (60.0, ["m", "min", "mins", "minute", "minutes", "minuten"]),
            (3600, ["h", "hr", "hrs", "hour", "hours", "std", "stunde", "stunden"]),
            (86400, ["d", "day", "days", "tag", "tage", "tagen"]),
            (604_800, ["w", "wk", "week", "weeks", "woche", "wochen"]),
        ] {
            for name in names { table[name] = seconds }
        }
        return table
    }()

    /// "in 1h 30m" → 5400 seconds. Nil unless the whole text is amounts with units.
    private static func timeSpan(_ text: String) -> TimeInterval? {
        guard var words = tokens(text) else { return nil }
        if words.first == "in" { words.removeFirst() }
        var total: TimeInterval = 0
        var amount: Double?
        for word in words where !["and", "und"].contains(word) {
            if let value = amount, let unit = secondsPerUnit[word] {
                total += value * unit
                amount = nil
            } else if amount == nil, let value = number(word) {
                amount = value
            } else {
                return nil
            }
        }
        return amount == nil && total > 0 ? total : nil
    }

    /// Splits "1.5h, 30m" into "1.5", "h", "30", "m": runs of digits and runs of letters, apart
    /// by spaces or commas. Nil for anything else, such as "-5m".
    private static func tokens(_ text: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        for char in text {
            let continuesNumber = current.first?.isNumber == true && (char.isNumber || char == "." || char == ",")
            let continuesWord = current.first?.isLetter == true && char.isLetter
            if continuesNumber || continuesWord { current.append(char); continue }
            guard char.isNumber || char.isLetter || char.isWhitespace || char == "," else { return nil }
            if !current.isEmpty { tokens.append(current) }
            current = char.isNumber || char.isLetter ? String(char) : ""
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func number(_ word: String) -> Double? {
        if ["a", "an", "ein", "eine", "einer", "einem"].contains(word) { return 1 }
        guard word.first?.isNumber == true else { return nil }
        return Double(word.replacingOccurrences(of: ",", with: "."))
    }

    /// "14:30", "9.15", "9am", "at 9:30 pm", "21 Uhr". A bare number isn't a time.
    private static func timeOfDay(_ text: String) -> DateComponents? {
        var text = Substring(text)
        for prefix in ["at ", "um "] where text.hasPrefix(prefix) { text = text.dropFirst(prefix.count) }
        var suffix: String?
        for word in ["am", "pm", "uhr"] where text.hasSuffix(word) {
            suffix = word
            text = text.dropLast(word.count)
        }
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: /[:.]/, omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.count == 2 || suffix != nil,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts[0].count <= 2, parts.count == 1 || parts[1].count == 2,
              var hour = Int(parts[0])
        else { return nil }
        let minute = parts.count == 2 ? Int(parts[1])! : 0
        switch suffix {
        case "am", "pm":
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (suffix == "pm" ? 12 : 0)
        default:
            guard (0...23).contains(hour) else { return nil }
        }
        guard (0...59).contains(minute) else { return nil }
        return DateComponents(hour: hour, minute: minute)
    }

    /// Dates and times written out, in English or the user's language, read by the system.
    private static func detectedDate(_ text: String) -> Date? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: whole)
        guard matches.count == 1, matches[0].range == whole else { return nil }
        return matches[0].date
    }
}
