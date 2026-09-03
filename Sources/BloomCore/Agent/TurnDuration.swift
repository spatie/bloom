import Foundation

/// Turn durations read the way Conductor writes them: "1m 52.6s" while the tenths still mean
/// something, "31m 43s" once they do not.
///
/// The minutes and the seconds are separated by a space rather than by a comma, because the
/// decimal separator is already a comma on half the machines this runs on and "3m, 34,0s" asks
/// one mark to mean two different things in one string.
///
/// The rounding is done before the unit is chosen rather than after. Formatting first and picking
/// the unit from the unrounded number is how 1,919,600 milliseconds came out as "31m, 60s" and
/// 59,950 as "60.0s": the seconds are under the threshold, the printed seconds are not.
public enum TurnDuration {
    private static func tenths(_ locale: Locale) -> FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(1)).locale(locale)
    }

    private static func whole(_ locale: Locale) -> FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0)).locale(locale)
    }

    /// The locale is a parameter with the right default rather than something read inside, so a
    /// test can pin it. A suite that leaves it to the machine passes in Brussels and fails in
    /// Boston over a comma.
    public static func format(_ milliseconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let seconds = max(0, Double(milliseconds)) / 1000

        // Rounded to the tenth the sub-minute form would print, so a value that prints as 60.0
        // is a minute here rather than a minute shaped second.
        if (seconds * 10).rounded() < 600 { return "\(seconds.formatted(tenths(locale)))s" }

        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)

        if minutes < 10 {
            // Same again one level up: 9m 59.97s prints its remainder as 60.0.
            return (remainder * 10).rounded() < 600
                ? "\(minutes)m \(remainder.formatted(tenths(locale)))s"
                : "\(minutes + 1)m \(Double.zero.formatted(tenths(locale)))s"
        }
        return remainder.rounded() < 60
            ? "\(minutes)m \(remainder.formatted(whole(locale)))s"
            : "\(minutes + 1)m 0s"
    }

    /// The turn footer's calm, whole-second form. A tenth of a second is useful while inspecting
    /// an individual action, but it is noise beside a completed answer.
    public static func wholeSeconds(_ milliseconds: Int) -> String {
        let seconds = Int((Double(max(0, milliseconds)) / 1000).rounded())
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes == 0 ? "\(seconds)s" : "\(minutes)m \(remainder)s"
    }

    /// The compact form a single row uses, where there is room for four characters at most.
    public static func short(_ milliseconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let clamped = max(0, milliseconds)
        if clamped < 1000 { return "\(clamped)ms" }

        let seconds = Double(clamped) / 1000
        if (seconds * 10).rounded() < 600 { return "\(seconds.formatted(tenths(locale)))s" }

        // At least one, because this branch is only reached once the seconds form would print as
        // sixty or more, and integer division gave 59,950 milliseconds the answer "0m".
        return "\(max(1, clamped / 60_000))m"
    }
}
