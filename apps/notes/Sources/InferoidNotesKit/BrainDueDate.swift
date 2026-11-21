import Foundation

/// Turns the short, spoken due phrases stored by the Brain into dates for sorting and urgency.
/// A phrase that cannot be understood deliberately returns nil; the UI keeps those items at the end.
public enum BrainDueDate {
    public static func resolve(_ phrase: String?, relativeTo meetingDate: String,
                               calendar suppliedCalendar: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        guard let phrase else { return nil }
        let rawText = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let text = rawText.hasPrefix("by ") ? String(rawText.dropFirst(3)) : rawText
        guard !text.isEmpty, let base = date(from: meetingDate) else { return nil }
        var calendar = suppliedCalendar
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let start = calendar.startOfDay(for: base)

        if text == "today" { return start }
        if text == "tomorrow" { return calendar.date(byAdding: .day, value: 1, to: start) }
        if text == "next week" { return calendar.date(byAdding: .day, value: 7, to: start) }
        if text == "end of month" || text == "the end of the month" {
            guard let range = calendar.range(of: .day, in: .month, for: start), let lastDay = range.last else { return nil }
            var components = calendar.dateComponents([.year, .month], from: start)
            components.day = lastDay
            return calendar.date(from: components)
        }
        if let match = text.range(of: #"^in\s+(\d+)\s+(day|days|week|weeks)$"#, options: .regularExpression) {
            let value = String(text[match]).split(separator: " ")
            guard value.count == 3, let number = Int(value[1]) else { return nil }
            let days = value[2].hasPrefix("week") ? number * 7 : number
            return calendar.date(byAdding: .day, value: days, to: start)
        }

        let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let weekdayText = text.replacingOccurrences(of: "this ", with: "")
        if let weekday = weekdayNames.firstIndex(of: weekdayText) {
            let current = calendar.component(.weekday, from: start) - 1
            var delta = (weekday - current + 7) % 7
            if delta == 0 && !text.hasPrefix("this ") { delta = 7 }
            return calendar.date(byAdding: .day, value: delta, to: start)
        }

        let formats = ["MMM d", "MMMM d", "MMM d, yyyy", "MMMM d, yyyy", "yyyy-MM-dd"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            if let parsed = formatter.date(from: text.capitalized) {
                if format.contains("yyyy") { return calendar.startOfDay(for: parsed) }
                var components = calendar.dateComponents([.month, .day], from: parsed)
                components.year = calendar.component(.year, from: start)
                guard let candidate = calendar.date(from: components) else { continue }
                if candidate < start { return calendar.date(byAdding: .year, value: 1, to: candidate) }
                return candidate
            }
        }
        return nil
    }

    private static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let date = formatter.date(from: value) { return date }
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.date(from: String(value.prefix(10)))
    }
}
