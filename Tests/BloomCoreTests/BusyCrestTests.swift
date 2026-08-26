import Foundation
import Testing
@testable import BloomCore

/// Asserted by shape rather than by its literals, the way `BusyDot` and `BusyRule` are, so the
/// crest can be retuned without rewriting the suite. What must not change is that it is a shape
/// with nothing at either end, that it is asymmetric in the direction it travels, that the rule
/// under it is never dark, and that holding it still leaves something worth looking at.
@Suite("The crest that travels the activity rule")
struct BusyCrestTests {
    // MARK: The profile

    /// A crest that did not reach zero would have a hard edge, and a hard edge on a moving gradient
    /// is a rectangle sliding along a line.
    @Test("it is nothing at either end and the accent at its peak")
    func endsAtNothing() {
        #expect(BusyCrest.profile(atFraction: 0) == 0)
        #expect(BusyCrest.profile(atFraction: 1) == 0)
        #expect(abs(BusyCrest.profile(atFraction: BusyCrest.peak) - 1) < 1e-12)
        #expect(BusyCrest.peakOpacity == 1)
    }

    @Test("it rises to the peak and falls away from it, and never leaves the range")
    func risesAndFalls() {
        var previous = BusyCrest.profile(atFraction: 0)
        for step in 1...1000 {
            let fraction = Double(step) / 1000
            let value = BusyCrest.profile(atFraction: fraction)
            #expect(value >= 0 && value <= 1)
            if fraction <= BusyCrest.peak {
                #expect(value >= previous - 1e-12, "the face should not dip on its way up")
            } else {
                #expect(value <= previous + 1e-12, "the tail should not lift on its way down")
            }
            previous = value
        }
    }

    /// The whole of the directionality, and the one property a single frame carries. A symmetric
    /// crest is a bulge whose heading has to be watched for; this one is read.
    ///
    /// Measured at half strength rather than at the peak, because that is the width the eye
    /// actually picks up: the distance from the peak back to where the crest has halved is several
    /// times the distance forward to the same point.
    @Test("the tail behind the peak is longer than the face in front of it")
    func isAsymmetric() {
        let behind = BusyCrest.peak - firstFraction(reaching: 0.5, from: 0, to: BusyCrest.peak)
        let ahead = firstFraction(reaching: 0.5, from: 1, to: BusyCrest.peak) - BusyCrest.peak
        #expect(behind > ahead * 2, "a head this soft says nothing about which way it is going")
    }

    // MARK: The stops

    /// Both gradients this feeds want locations that ascend and cover the whole figure, and both of
    /// them draw something wrong rather than refusing when they do not.
    @Test("the stops span the crest in order")
    func stopsAreOrdered() {
        let stops = BusyCrest.stops()
        #expect(stops.count > 2)
        #expect(stops.first?.location == 0)
        #expect(stops.last?.location == 1)
        #expect(stops.first?.opacity == 0)
        #expect(stops.last?.opacity == 0)
        for pair in zip(stops, stops.dropFirst()) {
            #expect(pair.1.location > pair.0.location)
        }
    }

    /// A train is the crest repeated, so nothing about its shape is a second decision. What this
    /// holds is the join: the last stop has to be the first one, or a gradient translated by
    /// exactly one wavelength shows a seam once a beat.
    @Test("the train tiles the same crest and closes on itself")
    func trainTiles() {
        let stops = BusyCrest.waveStops(wavelengths: 3, samplesEach: 12)
        #expect(stops.count == 37)
        #expect(stops.first?.location == 0)
        #expect(stops.last?.location == 1)
        #expect(stops.first?.opacity == stops.last?.opacity)
        for pair in zip(stops, stops.dropFirst()) {
            #expect(pair.1.location > pair.0.location)
        }
        // Every wavelength is the same shape, which is the point of tiling one profile.
        for step in 0..<12 {
            #expect(abs(stops[step].opacity - stops[step + 12].opacity) < 1e-12)
            #expect(abs(stops[step].opacity - stops[step + 24].opacity) < 1e-12)
        }
    }

    // MARK: The travel

    /// It enters and it leaves. A crest that started with its tail already on the rule would begin
    /// each cycle as a shape appearing out of nothing at the edge.
    @Test("it begins and ends entirely off the rule")
    func travelsClearOfBothEnds() {
        let travel = BusyCrest.travel(alongWidth: 900)
        #expect(travel.lowerBound + BusyCrest.length / 2 <= 0)
        #expect(travel.upperBound - BusyCrest.length / 2 >= 900)
    }

    /// A rule with no width yet is a view that has not been laid out. It must not produce a travel
    /// that runs backwards, because a `ClosedRange` built the wrong way round traps.
    @Test("a rule with no width still gives a range")
    func travelSurvivesNoWidth() {
        let travel = BusyCrest.travel(alongWidth: 0)
        #expect(travel.lowerBound <= travel.upperBound)
        #expect(BusyCrest.travel(alongWidth: -50).lowerBound <= BusyCrest.travel(alongWidth: -50).upperBound)
    }

    /// What `Reduce Motion` draws, and what every offscreen render photographs. The head is against
    /// the trailing edge with the tail behind it, so the still figure is a mark pointing at the
    /// place the next word arrives rather than a frame of an animation somebody stopped.
    @Test("held still, the crest parks its head at the trailing edge")
    func restsAtTheTrailingEdge() {
        let centre = BusyCrest.restingCentre(alongWidth: 900)
        #expect(centre + BusyCrest.length / 2 == 900)
        #expect(centre - BusyCrest.length / 2 >= 0)
    }

    /// The inspector's rule is 380 points and a pane can be dragged narrower than that. A crest
    /// longer than the rule it is parked on is centred rather than hung off the end, so the still
    /// figure is never just a tail with its head cut off.
    @Test("a rule shorter than the crest gets it centred")
    func restsCentredOnAShortRule() {
        let width = BusyCrest.length / 2
        #expect(BusyCrest.restingCentre(alongWidth: width) == width / 2)
        #expect(BusyCrest.restingCentre(alongWidth: 0) == 0)
    }

    @Test("the train covers the rule with a wavelength to spare")
    func trainCoversTheRule() {
        for width in [0.0, 100, 380, 900, 2000] {
            let count = BusyCrest.wavelengths(alongWidth: width)
            #expect(count >= 2)
            #expect(Double(count) * BusyCrest.waveLength >= width + BusyCrest.waveLength - 1e-9)
        }
    }

    // MARK: The heartbeat

    /// Not free, and the same property `BusyRule` and `BusyBreath` are held to. Every moving mark in
    /// this window is phased off one instant, and that only keeps them together while their periods
    /// share whole multiples. This is what fails if the crest is retuned alone.
    @Test("the crest and the train are both on the window's heartbeat")
    func staysOnTheHeartbeat() {
        #expect((BusyCrest.period / BusyDot.period).truncatingRemainder(dividingBy: 1) == 0)
        #expect((BusyCrest.period / BusyCrest.wavePeriod).truncatingRemainder(dividingBy: 1) == 0)
        #expect(BusyCrest.wavePeriod == BusyDot.period)
    }

    /// The three things the report on the old rule named, as numbers. The track is what stops a
    /// glance landing on a dark frame, and it has to be brighter than the bottom of the pulse it
    /// replaced or nothing was gained; the crest has to be thicker than the line it rides, or the
    /// difference is alpha again.
    @Test("it is lit everywhere and thicker than the rule it rides")
    func answersTheComplaint() {
        #expect(BusyCrest.trackOpacity > BusyRule.restingOpacity)
        #expect(BusyCrest.trackOpacity < BusyCrest.peakOpacity)
        #expect(BusyCrest.thickness > BusyRule.restingHeight)
        #expect(BusyCrest.glowHeight < BusyCrest.thickness)
        #expect(BusyCrest.glowShare < 1, "a glow as strong as the core is a thicker core")
    }

    /// Walks in from `from` towards `to` and answers where the profile first reaches `value`. The
    /// two ends are handed in either order, so one helper serves both sides of the peak.
    private func firstFraction(reaching value: Double, from: Double, to: Double) -> Double {
        let steps = 10_000
        for step in 0...steps {
            let fraction = from + (to - from) * Double(step) / Double(steps)
            if BusyCrest.profile(atFraction: fraction) >= value { return fraction }
        }
        return to
    }
}
