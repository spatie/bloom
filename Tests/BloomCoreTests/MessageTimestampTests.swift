import Foundation
import Testing
@testable import BloomCore

/// The wording of a message's hover time. Dates are built, never read off the clock, and the
/// calendar and locale are fixed so the day and month names spell the same on every machine.
@Suite("Message timestamp")
struct MessageTimestampTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
        return calendar
    }()
    private static let locale = Locale(identifier: "en_GB")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 14, _ minute: Int = 32) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func label(_ then: Date, now: Date) -> String {
        MessageTimestamp.label(for: then, now: now, calendar: Self.calendar, locale: Self.locale)
    }

    // Wednesday 14 October 2026.
    private var now: Date { date(2026, 10, 14, 18, 0) }

    @Test func todayIsTheClockAlone() {
        #expect(label(date(2026, 10, 14, 9, 5), now: now) == "9:05")
    }

    @Test func yesterdayIsNamedAsSuch() {
        #expect(label(date(2026, 10, 13, 23, 59), now: now) == "Yesterday 23:59")
    }

    @Test func midnightSeparatesTodayFromYesterday() {
        let justAfterMidnight = date(2026, 10, 14, 0, 1)
        let justBefore = date(2026, 10, 13, 23, 59)
        #expect(label(justAfterMidnight, now: now) == "0:01")
        #expect(label(justBefore, now: now).hasPrefix("Yesterday"))
    }

    @Test func thisWeekIsNamedByWeekday() {
        #expect(label(date(2026, 10, 12), now: now) == "Monday 14:32")
        #expect(label(date(2026, 10, 8), now: now) == "Thursday 14:32")
    }

    @Test func aWeekBackIsADateRatherThanAmbiguousWeekday() {
        #expect(label(date(2026, 10, 7), now: now) == "7 Oct 14:32")
    }

    @Test func earlierThisYearOmitsTheYear() {
        #expect(label(date(2026, 3, 2), now: now) == "2 Mar 14:32")
    }

    @Test func anotherYearKeepsIt() {
        #expect(label(date(2025, 12, 24), now: now) == "24 Dec 2025 14:32")
    }

    @Test func aFutureDateIsNeverCalledYesterday() {
        #expect(label(date(2026, 10, 20), now: now) == "20 Oct 14:32")
    }
}
