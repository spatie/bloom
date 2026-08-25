import Testing
import Foundation
@testable import BloomCore

@Suite("What a probe's report is made of")
struct ProbeStatsTests {
    @Test("a percentile of nothing is nought rather than a trap")
    func empty() {
        #expect(ProbeStats.percentile(0.5, of: []) == 0)
        #expect(ProbeStats.percentile(0.99, of: []) == 0)
    }

    @Test("the ends and the middle")
    func ends() {
        let sorted = [1.0, 2, 3, 4, 5]
        #expect(ProbeStats.percentile(0, of: sorted) == 1)
        #expect(ProbeStats.percentile(0.5, of: sorted) == 3)
        #expect(ProbeStats.percentile(1, of: sorted) == 5)
    }

    /// A fraction is a literal at every call site today. It is clamped anyway, because the day one
    /// of them is worked out from a count instead is the day this traps in the last line of a
    /// twenty minute run, which is a failure this family has had once already.
    @Test("a fraction outside 0...1 lands on an end")
    func outsideTheRange() {
        let sorted = [1.0, 2, 3]
        #expect(ProbeStats.percentile(-1, of: sorted) == 1)
        #expect(ProbeStats.percentile(2, of: sorted) == 3)
        #expect(ProbeStats.percentile(.nan, of: sorted) == 1)
    }

    /// The claim the review made about the two copies and could not check: `FrameProbe` clamped
    /// the index and then read it, `ScrollProbe` read it and then clamped. They agree, on every
    /// length from one to fifty and on the four fractions the reports actually ask for, and that
    /// is now something the suite says rather than something a reader works out.
    @Test("both spellings the probes used agree with this one")
    func theTwoOldSpellingsAgree() {
        for count in 1...50 {
            let sorted = (0..<count).map(Double.init)
            for fraction in [0.5, 0.95, 0.99, 1.0] {
                let clampedThenRead = sorted[
                    min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
                ]
                let readThenClamped = sorted[
                    min(max(Int((Double(sorted.count - 1) * fraction).rounded()), 0), sorted.count - 1)
                ]
                let now = ProbeStats.percentile(fraction, of: sorted)
                #expect(now == clampedThenRead)
                #expect(now == readThenClamped)
            }
        }
    }

    /// And the third spelling. `IdleProbe` took its median as `sorted[count / 2]`, which is a
    /// different formula and the same answer: the two disagree on no length, because rounding
    /// half away from zero at the halfway mark is what integer division does going up.
    @Test("the median by halving the count is the same number")
    func theHalvedMedianAgrees() {
        for count in 1...50 {
            let sorted = (0..<count).map(Double.init)
            #expect(ProbeStats.percentile(0.5, of: sorted) == sorted[sorted.count / 2])
        }
    }

    @Test("a window size is WxH and nothing else")
    func windowSize() {
        #expect(ProbeStats.windowSize("1440x900") == CGSize(width: 1440, height: 900))
        #expect(ProbeStats.windowSize("1440.5x900.25") == CGSize(width: 1440.5, height: 900.25))
        #expect(ProbeStats.windowSize("1440") == nil)
        #expect(ProbeStats.windowSize("1440x") == nil)
        #expect(ProbeStats.windowSize("axb") == nil)
        #expect(ProbeStats.windowSize("1440x900x600") == nil)
        // A zero is refused rather than applied, because a window cannot be measured at nought
        // and a run that tried would report frame times for nothing at all.
        #expect(ProbeStats.windowSize("0x900") == nil)
        #expect(ProbeStats.windowSize("1440x0") == nil)
    }
}
