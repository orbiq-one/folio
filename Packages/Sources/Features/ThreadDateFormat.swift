import Foundation

enum ThreadDateFormat {
    static func absoluteString(for date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let relative = string(for: date, now: now, calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) { return relative }
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        return "\(relative), \(time)"
    }

    static func compact(for date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "now") }
        if seconds < 3_600 { return String(localized: "\(Int(seconds / 60))m") }
        if seconds < 86_400 { return String(localized: "\(Int(seconds / 3_600))h") }
        if seconds < 7 * 86_400 { return String(localized: "\(Int(seconds / 86_400))d") }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(style.month(.abbreviated).day()) }
        return date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    static func string(for date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return "\(String(localized: "Today")) \(date.formatted(style.hour().minute()))" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return String(localized: "Yesterday") }
        if (2...6).contains(days) { return date.formatted(style.weekday(.wide)) }
        return date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }
}
