import Foundation
import Testing
@testable import BloomCore

/// How long a turn took, written the way Conductor writes it.
///
/// Every expectation is pinned to one locale. These numbers go through `formatted`, which is
/// locale aware on purpose, so a suite that let the machine decide would read "1,0s" in Brussels
/// and "1.0s" in Boston.
@Suite("Turn duration")
struct TurnDurationTests {
    private static let locale = Locale(identifier: "en_US")

    private func format(_ milliseconds: Int) -> String {
        TurnDuration.format(milliseconds, locale: Self.locale)
    }

    private func short(_ milliseconds: Int) -> String {
        TurnDuration.short(milliseconds, locale: Self.locale)
    }

    @Test(
        "under a minute reads in tenths of a second",
        arguments: [
            (0, "0.0s"),
            (100, "0.1s"),
            (1_000, "1.0s"),
            (52_600, "52.6s"),
            (59_900, "59.9s"),
        ]
    )
    func subMinute(milliseconds: Int, expected: String) {
        #expect(format(milliseconds) == expected)
    }

    @Test(
        "a value that would print as sixty seconds is a minute, not a minute shaped second",
        arguments: [
            (59_950, "1m 0.0s"),
            (59_990, "1m 0.0s"),
            (60_000, "1m 0.0s"),
        ]
    )
    func sixtySecondsRollsOver(milliseconds: Int, expected: String) {
        #expect(format(milliseconds) == expected)
    }

    @Test(
        "under ten minutes keeps the tenths, past that it drops them",
        arguments: [
            (112_600, "1m 52.6s"),
            (599_000, "9m 59.0s"),
            (1_903_000, "31m 43s"),
        ]
    )
    func minutes(milliseconds: Int, expected: String) {
        #expect(format(milliseconds) == expected)
    }

    @Test(
        "a remainder that would print as sixty carries into the minutes at either precision",
        arguments: [
            (599_990, "10m 0.0s"),
            (1_919_600, "32m 0s"),
            (1_919_990, "32m 0s"),
        ]
    )
    func remainderCarries(milliseconds: Int, expected: String) {
        #expect(format(milliseconds) == expected)
    }

    @Test("a negative duration is read as none rather than as a minus sign in a row")
    func negative() {
        #expect(format(-5) == "0.0s")
        #expect(short(-5) == "0ms")
    }

    @Test(
        "the compact form fits in four characters",
        arguments: [
            (0, "0ms"),
            (999, "999ms"),
            (1_000, "1.0s"),
            (59_900, "59.9s"),
            (59_950, "1m"),
            (60_000, "1m"),
            (3_600_000, "60m"),
        ]
    )
    func short(milliseconds: Int, expected: String) {
        #expect(short(milliseconds) == expected)
    }
}
