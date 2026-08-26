import Testing
@testable import BloomCore

/// Asserted by shape rather than by its literals, so the rule can be retuned without rewriting the
/// suite. What must not change is that the rule brightens rather than dims, that it reaches the
/// accent undiluted at the top, that it never goes out, and that it rests where a still is taken.
@Suite("The pulse the activity rule moves on")
struct BusyRuleTests {
    /// The complaint the whole change came from: a mark the same shade as the line it sits on is
    /// no mark at all. The top of this pulse is the accent itself, and anything less puts that
    /// back.
    @Test("it brightens to the accent undiluted")
    func brightensToTheAccent() {
        #expect(BusyRule.opacity(at: 1) > BusyRule.opacity(at: 0))
        #expect(BusyRule.opacity(at: 1) == 1)
    }

    /// A rule that reaches nothing is absent for part of every cycle, and a line under the title
    /// bar that comes and goes reads as a redraw fault rather than as a signal.
    @Test("it never goes out")
    func neverGoesOut() {
        for step in 0...100 {
            let pulse = Double(step) / 100
            #expect(BusyRule.opacity(at: pulse) >= BusyRule.restingOpacity)
            #expect(BusyRule.opacity(at: pulse) <= 1)
        }
    }

    /// What `Reduce Motion` draws and what an offscreen render photographs. A rule held mid pulse
    /// would put a different line in every screenshot of a working window.
    @Test("the still figure is the bottom of the pulse")
    func restsAtTheBottom() {
        #expect(BusyRule.opacity(at: BusyRule.resting) == BusyRule.restingOpacity)
    }

    /// Not free. Every moving mark in the window is phased off one instant, and that only keeps
    /// them together while their periods share whole multiples. The rule and the dot swell
    /// together, so theirs is the same number, and this is what fails if one of them is retuned
    /// alone.
    @Test("the rule and the dot are on one wave")
    func sharesTheDotsWave() {
        #expect(BusyRule.period == BusyDot.period)
        #expect((BusyBreath.period / BusyRule.period).truncatingRemainder(dividingBy: 1) == 0)
    }

    /// A caller handing this an absolute phase is handing it something it did not clamp itself.
    @Test("anything outside the pulse is held at its ends")
    func clamped() {
        #expect(BusyRule.opacity(at: -1) == BusyRule.opacity(at: 0))
        #expect(BusyRule.opacity(at: 2) == BusyRule.opacity(at: 1))
    }
}
