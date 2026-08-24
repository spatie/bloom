import Testing
@testable import BloomCore

/// The breath is asserted by shape rather than by its literals, so the curve can be retuned without
/// rewriting the suite. What must not change is that it breathes: arrives, holds, falls, rests.
@Suite("The breath a slow mark moves on")
struct BusyBreathTests {
    @Test("the four stretches account for the whole period")
    func stretchesFillThePeriod() {
        let total = BusyBreath.inhale + BusyBreath.held + BusyBreath.exhale + BusyBreath.rest
        #expect(abs(total - 1) < 1e-12)
        #expect(BusyBreath.rest > 0, "a breath needs a pause at the bottom, or it is a pulse")
    }

    @Test("it rests at the bottom and arrives at the top")
    func endpoints() {
        #expect(BusyBreath.value(atPhase: 0) == 0)
        #expect(abs(BusyBreath.value(atPhase: BusyBreath.inhale) - 1) < 1e-12)
        #expect(abs(BusyBreath.value(atPhase: BusyBreath.inhale + BusyBreath.held) - 1) < 1e-12)
        #expect(BusyBreath.value(atPhase: 0.999) == 0)
    }

    @Test("it never leaves nought to one")
    func bounded() {
        for step in 0...1000 {
            let value = BusyBreath.value(atPhase: Double(step) / 1000)
            #expect(value >= 0 && value <= 1)
        }
    }

    @Test("it rises through the inhale and falls through the exhale, without reversing")
    func monotonicWhereItMoves() {
        var previous = -1.0
        for step in 0...100 {
            let phase = BusyBreath.inhale * Double(step) / 100
            let value = BusyBreath.value(atPhase: phase)
            #expect(value >= previous)
            previous = value
        }

        let start = BusyBreath.inhale + BusyBreath.held
        previous = 2.0
        for step in 0...100 {
            let phase = start + BusyBreath.exhale * Double(step) / 100
            let value = BusyBreath.value(atPhase: phase)
            #expect(value <= previous)
            previous = value
        }
    }

    /// The asymmetry is the whole point: a sine spends equal time going each way and reads as a
    /// status light. So the breath must be past halfway well before the middle of its own inhale.
    @Test("the inhale arrives rather than creeps")
    func inhaleIsEasedOut() {
        #expect(BusyBreath.value(atPhase: BusyBreath.inhale / 2) > 0.5)
        #expect(BusyBreath.exhale > BusyBreath.inhale, "falling should take longer than filling")
    }

    @Test("it wraps, so an absolute time can be handed straight in")
    func wraps() {
        for phase in [0.3, 0.61, 0.87] {
            #expect(abs(BusyBreath.value(atPhase: phase) - BusyBreath.value(atPhase: phase + 4)) < 1e-12)
        }
    }

    @Test("the samples close on themselves and stay smooth")
    func samples() {
        let samples = BusyBreath.samples()
        #expect(samples.count == 49)
        #expect(samples.first == samples.last, "a repeating animation has to close on itself")

        // Linear interpolation between samples is only invisible while neighbours are close. If a
        // future count leaves a step this large, the eye will find it.
        let biggestStep = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(biggestStep < 0.2)
    }

    /// The period is not free: every moving mark in the window is phased off one instant, and that
    /// only keeps them together while the periods share whole multiples. The rule crosses in
    /// `BusyPulse.pass`, which is three seconds.
    @Test("the period is a whole number of seconds, so the marks cannot drift apart")
    func periodStaysInRatio() {
        #expect(BusyBreath.period == 3)
        #expect(BusyBreath.period.truncatingRemainder(dividingBy: 1) == 0)
    }
}

@Suite("The two rings the sidebar breathes with")
struct BusyBreathRingsTests {
    @Test("the rings approach each other and part again")
    func gapCloses() {
        let atRest = gap(at: 0)
        let atTop = gap(at: 1)
        #expect(atRest > atTop, "the gap is what breathes, and it closes at the top")
        #expect(atTop > 0, "they almost meet, they do not cross")
    }

    @Test("the inner ring grows while the outer shrinks")
    func opposedMotion() {
        let innerLow = BusyBreath.Rings.innerScale(at: 0)
        let innerHigh = BusyBreath.Rings.innerScale(at: 1)
        let outerLow = BusyBreath.Rings.outerScale(at: 0)
        let outerHigh = BusyBreath.Rings.outerScale(at: 1)
        #expect(innerHigh > innerLow)
        #expect(outerHigh < outerLow)
    }

    /// A ring scaled past the radius its path was built at would thicken and soften, which at this
    /// size looks like a focus problem rather than a design.
    @Test("neither ring is ever scaled up")
    func onlyEverScaledDown() {
        for step in 0...100 {
            let breath = Double(step) / 100
            #expect(BusyBreath.Rings.innerScale(at: breath) <= 1)
            #expect(BusyBreath.Rings.outerScale(at: breath) <= 1)
            #expect(BusyBreath.Rings.innerScale(at: breath) > 0)
            #expect(BusyBreath.Rings.outerScale(at: breath) > 0)
        }
    }

    /// The figure must never go out. A mark that goes dark is a different shape twice a beat, and
    /// the shape is what this column is read by.
    @Test("nothing ever reaches nought opacity")
    func neverGoesOut() {
        #expect(BusyBreath.Rings.innerOpacity > 0.5)
        for step in 0...100 {
            #expect(BusyBreath.Rings.outerOpacity(at: Double(step) / 100) >= 0.5)
        }
    }

    @Test("the outer ring brightens as it closes in")
    func outerBrightensAsItTightens() {
        #expect(BusyBreath.Rings.outerOpacity(at: 1) > BusyBreath.Rings.outerOpacity(at: 0))
    }

    /// What the mark rests at when the heartbeat stops. Both rings visible, neither at an extreme.
    @Test("the resting figure is two separated rings")
    func restsHalfOpen() {
        let resting = gap(at: 0.5)
        #expect(resting > 0.5, "half open has to look like two rings, not one thick one")
        #expect(resting < gap(at: 0))
    }

    private func gap(at breath: Double) -> Double {
        let inner = BusyBreath.Rings.innerScale(at: breath) * BusyBreath.Rings.innerDrawn
        let outer = BusyBreath.Rings.outerScale(at: breath) * BusyBreath.Rings.outerDrawn
        return outer - inner
    }
}
