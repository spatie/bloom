import Testing
@testable import BloomCore

/// Asserted by shape rather than by its literals, so the pulse can be retuned without rewriting
/// the suite. What must not change is that the dot swells as it fades, never goes out, is only
/// ever scaled down from the path it is drawn at, and rests as a whole mark.
@Suite("The pulse a busy mark moves on")
struct BusyDotTests {
    /// The one number here that is not free. Every mark phases off `BusyPulse.epoch`, and that
    /// only puts them on one heartbeat while the periods stay in whole number ratios: the light on
    /// the rule crosses in `BusyPulse.pass`, which is three seconds, and its whole figure is six.
    @Test("a pulse divides a crossing of the rule")
    func periodDividesTheSweep() {
        #expect(BusyDot.period == 1.5)
        #expect((3 / BusyDot.period).truncatingRemainder(dividingBy: 1) == 0)
        #expect((6 / BusyDot.period).truncatingRemainder(dividingBy: 1) == 0)
    }

    @Test("it swells as it fades")
    func swellsAsItFades() {
        #expect(BusyDot.scale(at: 1) > BusyDot.scale(at: 0))
        #expect(BusyDot.opacity(at: 1) < BusyDot.opacity(at: 0))
    }

    /// A mark that reaches nothing is absent for part of every cycle, and this column is read at a
    /// glance rather than watched.
    @Test("it never goes out and never vanishes")
    func neverGoesOut() {
        for step in 0...100 {
            let pulse = Double(step) / 100
            #expect(BusyDot.opacity(at: pulse) >= 0.5)
            #expect(BusyDot.scale(at: pulse) >= 1)
        }
    }

    /// A filled circle resampled smaller keeps a clean edge; one scaled past the size its path was
    /// built at softens.
    @Test("the figure is only ever scaled down")
    func onlyEverScaledDown() {
        for step in 0...100 {
            let pulse = Double(step) / 100
            #expect(BusyDot.pathScale(at: pulse) <= 1)
            #expect(BusyDot.pathScale(at: pulse) > 0)
        }
        #expect(abs(BusyDot.pathScale(at: 1) - 1) < 1e-12, "the top of the pulse is the path itself")
    }

    /// What `Reduce Motion` draws and what an offscreen render photographs. A dot held mid pulse
    /// would be read as faded rather than as still.
    @Test("the resting figure is the whole mark")
    func restsWhole() {
        #expect(BusyDot.scale(at: BusyDot.resting) == 1)
        #expect(BusyDot.opacity(at: BusyDot.resting) == 1)
    }

    /// A caller handing this an absolute phase is handing it something it did not clamp itself.
    @Test("anything outside the pulse is held at its ends")
    func clamped() {
        #expect(BusyDot.scale(at: -1) == BusyDot.scale(at: 0))
        #expect(BusyDot.scale(at: 2) == BusyDot.scale(at: 1))
        #expect(BusyDot.opacity(at: -1) == BusyDot.opacity(at: 0))
        #expect(BusyDot.opacity(at: 2) == BusyDot.opacity(at: 1))
    }
}
