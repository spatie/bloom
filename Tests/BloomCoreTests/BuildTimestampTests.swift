import Foundation
import Testing
@testable import BloomCore

/// What this file is about: several development builds exist on this machine at once, and until
/// the About window learned to print a time they all printed the same line. Every case below is
/// either a source the date can come from or a decision about how much of it is worth showing.
///
/// Fixed locale, zone and clock throughout. Anything reading `.autoupdatingCurrent` here would be
/// a test that passes in this office and fails in the next region.
@Suite("Build timestamp")
struct BuildTimestampTests {
    private static let brussels = TimeZone(identifier: "Europe/Brussels")!
    /// Freek's machine is English with a Belgian region, which is a 24 hour clock and the day
    /// before the month. `en_GB` is the stable identifier that resolves the same way.
    private static let belgium = Locale(identifier: "en_GB")

    private static func moment(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = brussels
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    private static func line(_ date: Date, now: Date) -> String {
        BuildTimestamp.line(date, now: now, locale: belgium, timeZone: brussels)
    }

    @Test("A build from this year is a day, a month and a clock, and nothing else")
    func compactWithinTheYear() {
        #expect(
            Self.line(Self.moment(2026, 8, 23, 14, 32), now: Self.moment(2026, 8, 23, 18, 0))
                == "23 Aug 14:32"
        )
    }

    /// The one thing worse than a long line is two builds a year apart that read identically.
    @Test("A build from another year carries the year, because the day alone would collide")
    func yearAppearsWhenItDiffers() {
        #expect(
            Self.line(Self.moment(2025, 8, 23, 14, 32), now: Self.moment(2026, 8, 23, 18, 0))
                == "23 Aug 2025 14:32"
        )
    }

    /// Not a formatting preference: the line is a spec in a small mono face beside a label and a
    /// commit, and seconds are precision about something this is not being asked to separate.
    @Test("No seconds, ever")
    func secondsAreNotShown() {
        let line = Self.line(Self.moment(2026, 1, 2, 9, 5), now: Self.moment(2026, 1, 2, 9, 6))

        #expect(line == "2 Jan 09:05")
        #expect(line.filter { $0 == ":" }.count == 1)
    }

    /// The day and month order, the month's abbreviation and the 24 hour clock all belong to the
    /// reader rather than to this repository, which is why the format is asked for by template.
    @Test("The reader's locale decides the order and the clock")
    func localeDecidesTheShape() {
        let built = Self.moment(2026, 8, 23, 14, 32)
        let now = Self.moment(2026, 8, 23, 18, 0)

        // Spaces normalised, because ICU sets a narrow no break space in front of the meridiem
        // and an assertion against a plain one fails while printing two identical looking strings.
        let american = BuildTimestamp.line(
            built, now: now, locale: Locale(identifier: "en_US"), timeZone: Self.brussels
        ).map { $0.isWhitespace ? " " : $0 }

        #expect(String(american) == "Aug 23 2:32 PM")
        #expect(
            BuildTimestamp.line(
                built, now: now, locale: Locale(identifier: "nl_BE"), timeZone: Self.brussels
            ) == "23 aug 14:32"
        )
    }

    @Test("The stamp is stored in UTC and read in the reader's own zone")
    func stampIsUTCAndDisplayedLocally() {
        let parsed = BuildTimestamp.parse("2026-08-23T12:32:00Z")

        #expect(parsed == Self.moment(2026, 8, 23, 14, 32))
        #expect(Self.line(parsed!, now: Self.moment(2026, 8, 23, 18, 0)) == "23 Aug 14:32")
    }

    @Test("Absent, blank and malformed stamps are all absent")
    func unusableStampsAreNil() {
        #expect(BuildTimestamp.parse(nil) == nil)
        #expect(BuildTimestamp.parse("   ") == nil)
        #expect(BuildTimestamp.parse("last Tuesday") == nil)
    }

    /// The stamp is the fact and the mtime is the approximation, so the fact wins whenever there
    /// is one. A bundle that has been copied or re-signed since it was built has an mtime hours
    /// away from its own build time, and the stamp is still right.
    @Test("A stamped bundle never falls back to the file date")
    func stampOutranksTheFileDate() {
        let stamped = BuildTimestamp.read(
            stamp: "2026-08-23T12:32:00Z", executableModified: Self.moment(2026, 8, 24, 9, 0)
        )

        #expect(stamped == Self.moment(2026, 8, 23, 14, 32))
    }

    /// The bundles already installed on this machine were assembled before the key existed. They
    /// are exactly the copies somebody is trying to tell apart, so they get the approximation
    /// rather than a blank, and it is right about which of two builds is the newer.
    @Test("A bundle built before the key existed falls back to the executable's date")
    func fileDateCoversOlderBundles() {
        let mtime = Self.moment(2026, 8, 20, 10, 15)

        #expect(BuildTimestamp.read(stamp: nil, executableModified: mtime) == mtime)
        #expect(BuildTimestamp.read(stamp: "  ", executableModified: mtime) == mtime)
        #expect(BuildTimestamp.read(stamp: "not a date", executableModified: mtime) == mtime)
        #expect(BuildTimestamp.read(stamp: nil, executableModified: nil) == nil)
    }
}
