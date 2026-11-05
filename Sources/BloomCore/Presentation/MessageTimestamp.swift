import Foundation

/// The time shown while the pointer rests on a message, worded the way iMessage words it: the
/// clock for today, then the day, then the date as the message gets older.
///
/// Calendar and locale are parameters so a test can fix both and never depend on this Mac.
public enum MessageTimestamp {
    /// Days back, inclusive, that are named by weekday. Past a week the name is ambiguous.
    private static let weekdayWindow = 6

    public static func label(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = clock(date, calendar: calendar, locale: locale)
        let daysAgo = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0

        switch daysAgo {
        case 0:
            return time
        case 1:
            return "Yesterday \(time)"
        case 2...weekdayWindow:
            return "\(day(date, calendar: calendar, locale: locale) { $0.weekday(.wide) }) \(time)"
        default:
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            let calendarDay = day(date, calendar: calendar, locale: locale) {
                sameYear ? $0.day().month(.abbreviated) : $0.day().month(.abbreviated).year()
            }
            return "\(calendarDay) \(time)"
        }
    }

    private static func clock(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(
            date: .omitted, time: .shortened,
            locale: locale, calendar: calendar, timeZone: calendar.timeZone
        ))
    }

    private static func day(
        _ date: Date, calendar: Calendar, locale: Locale,
        fields: (Date.FormatStyle) -> Date.FormatStyle
    ) -> String {
        date.formatted(fields(Date.FormatStyle(
            locale: locale, calendar: calendar, timeZone: calendar.timeZone
        )))
    }
}
