import Foundation

/// Turn durations read the way Conductor writes them: "1m, 52.6s" while the tenths still mean
/// something, "31m, 43s" once they do not.
enum TurnDuration {
    private static let tenths = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
    private static let whole = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))

    static func format(_ milliseconds: Int) -> String {
        let seconds = Double(milliseconds) / 1000
        if seconds < 60 { return "\(seconds.formatted(tenths))s" }

        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return minutes < 10
            ? "\(minutes)m, \(remainder.formatted(tenths))s"
            : "\(minutes)m, \(remainder.formatted(whole))s"
    }

    /// The compact form a single row uses, where there is room for four characters at most.
    static func short(_ milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds)ms" }
        if milliseconds < 60_000 { return "\((Double(milliseconds) / 1000).formatted(tenths))s" }
        return "\(milliseconds / 60_000)m"
    }
}
