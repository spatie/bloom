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

    /// The retry glyph is a layer now, and what it is handed is these numbers. A mark that reaches
    /// nothing is absent for part of every cycle, which is the failure the floor exists to prevent.
    @Test("the breathing mark never goes out, and arrives at full strength")
    func opacityStaysOnScreen() {
        #expect(BusyBreath.opacity(atPhase: 0) == BusyBreath.restingOpacity)
        #expect(abs(BusyBreath.opacity(atPhase: BusyBreath.inhale) - 1) < 1e-12)

        for step in 0...1_000 {
            let value = BusyBreath.opacity(atPhase: Double(step) / 1_000)
            #expect(value >= BusyBreath.restingOpacity)
            #expect(value <= 1)
        }
    }

    @Test("the opacity samples close on themselves")
    func opacitySamplesClose() {
        let samples = BusyBreath.opacitySamples(count: 12)
        #expect(samples.count == 13)
        #expect(samples.first == samples.last)
        #expect(samples.max() == 1)
    }

    /// The period is not free: every moving mark in the window is phased off one instant, and that
    /// only keeps them together while the periods share whole multiples. The busy dot pulses in
    /// `BusyDot.period` and the rule under the title bar brightens on the same wave, which is a
    /// second and a half, so this is two of those.
    @Test("the period is a whole number of seconds, so the marks cannot drift apart")
    func periodStaysInRatio() {
        #expect(BusyBreath.period == 3)
        #expect(BusyBreath.period.truncatingRemainder(dividingBy: 1) == 0)
    }
}
