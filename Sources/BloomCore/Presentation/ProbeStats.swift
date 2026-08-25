import Foundation

/// The two pieces of arithmetic the window probes do, in the target that can test them.
///
/// Both were written more than once and neither was tested. `FrameProbe` clamped the index and
/// then read it, `ScrollProbe` read it and then clamped, and `IdleProbe` took a median by halving
/// the count: three spellings of one answer whose agreement was something a reader had to work
/// out rather than something the suite says. That matters more here than the duplication does. A
/// probe that computes a percentile a hair differently from its sibling makes two runs
/// incomparable, and two runs being comparable is the whole of what a measuring instrument is
/// for.
///
/// Here rather than beside the probes because a decision taken inside the app target is a
/// decision nothing can test, and neither of these needs a window to answer.
public enum ProbeStats {
    /// The value `fraction` of the way through `sorted`, which has to be sorted already.
    ///
    /// Nearest rank, rounding halves away from zero, clamped at both ends, so a fraction outside
    /// `0...1` returns an end rather than trapping. An empty list is nought rather than nil:
    /// every caller is writing a number into a report and has nothing better to write.
    public static func percentile(_ fraction: Double, of sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let last = Double(sorted.count - 1)
        // Clamped as a `Double` before the conversion rather than after it. `Int(_:)` traps on a
        // value `Int` cannot hold and on a NaN, and both probes that take a step or a sweep count
        // off the command line are one arithmetic mistake away from handing this one.
        let rank = min(last, max(0, (last * fraction).rounded()))
        return sorted[Int(rank)]
    }

    /// A window size as `--window-size` spells it: `1440x900`.
    ///
    /// Nil for anything else, a zero included, because the caller's answer to nil is to refuse
    /// the run rather than to carry on. A probe that quietly measured a window of some other size
    /// than the one its report names is a probe whose number means something else.
    public static func windowSize(_ raw: String) -> CGSize? {
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
