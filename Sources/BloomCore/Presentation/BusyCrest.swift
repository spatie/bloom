import Foundation

/// The crest that travels the activity rule while an agent is working: a bright swelling in the
/// line, running the way the answer is about to arrive.
///
/// # What it is answering
///
/// The rule used to brighten and dim across its whole width, and the report on it was "the busy
/// indicator, that breath of green line, is not clear at all". Three things made it quiet, and all
/// three are addressed here rather than by turning the opacity up.
///
/// **It was one point tall in both states.** A working rule and an idle one differed in alpha and
/// in nothing else, and alpha is the first thing peripheral vision throws away. The crest is three
/// points where the rule under it is one, so the line visibly thickens as it passes: a difference
/// in geometry, which is read at a glance and across a room.
///
/// **It had no direction.** A whole width brightening at once says "something is happening"; it
/// cannot say "text is coming". The crest travels towards the trailing edge, which is the end the
/// next word lands at.
///
/// **It went quiet between beats.** At the bottom of the old pulse the rule was a 0.32 tint, so a
/// glance that landed on the wrong half of the cycle found nothing. The crest rides a track that is
/// always lit at `trackOpacity`, so the rule is never at its dimmest anywhere, and the crest is a
/// gain on top of it.
///
/// # The profile, and why it is not symmetric
///
/// A symmetric bulge travelling a line reads as a bulge travelling a line, and which way it went is
/// something you work out by watching it for a second. This one has a short steep face at the head
/// and a long fade behind it, so a **single frame** says which way it is going. That matters twice
/// over: it is what a still of the app shows, and it is the whole of what `Reduce Motion` gets,
/// where the crest is parked at the trailing end and never moves. See `restingCentre`.
///
/// # Why the numbers live here
///
/// A view cannot be tested, so the shape of the motion is not a view's to own. What is here is the
/// figure and the travel; what is left to the mark is turning them into layers. `BusyDot`,
/// `BusyRule` and `BusyBreath` are the same split for the other three marks in this window.
public enum BusyCrest {
    /// One stop in the crest's profile: where along it, and how strongly it is drawn there.
    ///
    /// A type rather than a tuple because it crosses into two different gradients, a
    /// `CAGradientLayer` and a SwiftUI `LinearGradient`, and a pair of unlabelled doubles is how
    /// those two end up disagreeing about which one is which.
    public struct Stop: Equatable, Sendable {
        /// Along the crest, 0 at the tail and 1 at the head.
        public let location: Double
        /// What the accent is drawn at there, 0 for nothing at all.
        public let opacity: Double

        public init(location: Double, opacity: Double) {
            self.location = location
            self.opacity = opacity
        }
    }

    // MARK: The figure

    /// How long the crest is, in points.
    ///
    /// Long enough to be a shape rather than a dash, short enough that a rule holds several of its
    /// own lengths. The inspector's segment is 380 points, so even the narrowest rule in the window
    /// is two of these.
    public static let length = 190.0

    /// How thick it is, where the rule it travels is one point.
    ///
    /// Three, and the third point is not decoration: two is a rule somebody would read as a rule
    /// drawn slightly wrong, and three is unmistakably a swelling. It is drawn as one point of core
    /// on the rule's own line and two of softer glow above it, so the thickening has an edge rather
    /// than a step. See `glowShare`.
    public static let thickness = 3.0

    /// How much of the thickness is the softer half above the rule's own line.
    public static let glowHeight = 2.0

    /// What that softer half is drawn at, against the core's own strength.
    ///
    /// Half. The glow is what stops a three point bar reading as a box, and a glow as strong as the
    /// core is just a thicker box.
    public static let glowShare = 0.5

    /// What the rule holds everywhere the crest is not.
    ///
    /// Higher than the 0.32 the old pulse rested at, because that number was the bottom of a cycle
    /// that spent half its time above it, and this one is the whole of what most of the rule ever
    /// shows. It is also the floor under `Reduce Motion`, where nothing at all is moving.
    public static let trackOpacity = 0.42

    /// What the crest reaches at its peak: the accent, undiluted.
    ///
    /// The complaint the rule's own history records is a mark drawn in a shade of the line it sits
    /// on. Anything less than the whole accent here puts that straight back.
    public static let peakOpacity = 1.0

    /// Where the peak sits along the crest, from the tail.
    ///
    /// Near the head, so the steep face is short and the fade behind it is long. This one number is
    /// the whole of the directionality: at 0.5 the crest is symmetric and says nothing about which
    /// way it is going.
    public static let peak = 0.78

    /// How long one crossing takes.
    ///
    /// `BusyBreath.period`, which is two of `BusyDot.period`, so the crest leaves the rule on a
    /// frame where every dot in the window is at the top of its swell. The window has one
    /// heartbeat, and a figure whose period shares no whole multiple with the rest would be a
    /// second one beating against it.
    ///
    /// **The period is shared and the speed is not.** The centre column's rule and the inspector's
    /// are different lengths, so a fixed speed would have them finishing at different moments and a
    /// fixed period has them starting and finishing together. A shared instant is what
    /// `BusyPulse.epoch` is for, and it is worth more here than a shared speed: two rules crossing
    /// at once read as one signal, two rules crossing at their own rates read as two.
    public static var period: TimeInterval { BusyBreath.period }

    /// How far apart two crests sit in the train the `current` variant draws.
    ///
    /// Shorter than a lone crest, because a train is read as a texture rather than as a shape: at
    /// `length` apart the wave is so long that a narrow rule holds one trough and reads as the lone
    /// crest with extra steps.
    public static let waveLength = 120.0

    /// How long the train takes to travel one wavelength.
    ///
    /// `BusyDot.period`, so the train advances one whole crest between two beats of the window's
    /// heartbeat, and the figure closes on itself on the same frame the dots do.
    public static var wavePeriod: TimeInterval { BusyDot.period }

    // MARK: The profile

    /// How strongly the crest is drawn at a point along itself, 0 at the tail and 1 at the head.
    ///
    /// Nothing at either end and the peak at `peak`, with a smoothstep either side of it. The two
    /// sides are the same curve over different lengths, which is where the asymmetry comes from:
    /// there is no second shape to keep in agreement with the first, only a peak that is not in the
    /// middle.
    ///
    /// Anything outside 0 to 1 is held at the ends, so a caller sampling a gradient off the edge of
    /// the figure gets nothing rather than a negative.
    public static func profile(atFraction fraction: Double) -> Double {
        let f = min(max(fraction, 0), 1)
        if f >= peak {
            return smoothstep((1 - f) / (1 - peak))
        }
        return smoothstep(f / peak)
    }

    /// The profile sampled evenly, for a gradient that interpolates between the samples.
    ///
    /// Sampled rather than expressed as three stops with a curve between them, because neither
    /// `CAGradientLayer` nor SwiftUI's `LinearGradient` eases between stops at all: both are linear
    /// from one to the next, so a curve has to arrive as points on it. At the default count the
    /// samples are eight points apart on a 190 point crest, which is finer than the softness of the
    /// edge they are describing.
    public static func stops(count: Int = 24) -> [Stop] {
        precondition(count > 1, "a crest needs at least two stops")
        return (0...count).map { step in
            let location = Double(step) / Double(count)
            return Stop(location: location, opacity: profile(atFraction: location) * peakOpacity)
        }
    }

    /// The same profile tiled, for the train the `current` variant travels.
    ///
    /// One shape rather than two: a train of crests is the crest repeated, and a second envelope
    /// written for it could only ever drift from the first. The locations run across the whole
    /// train, so this drops straight into one gradient rather than into one gradient per crest.
    public static func waveStops(wavelengths: Int, samplesEach: Int = 12) -> [Stop] {
        precondition(wavelengths > 0, "a train needs at least one crest")
        precondition(samplesEach > 1, "a crest needs at least two stops")
        let total = wavelengths * samplesEach
        return (0...total).map { step in
            let location = Double(step) / Double(total)
            let within = Double(step % samplesEach) / Double(samplesEach)
            // The last sample of the train closes on the first, so a gradient translated by exactly
            // one wavelength has no seam at the join.
            let fraction = step == total ? 0 : within
            return Stop(location: location, opacity: profile(atFraction: fraction) * peakOpacity)
        }
    }

    // MARK: The travel

    /// Where the centre of the crest starts and ends, along a rule of this width.
    ///
    /// It begins entirely off the leading edge and ends entirely off the trailing one, so the crest
    /// is never sitting still at either end of the rule waiting for the cycle to come round. What
    /// the reader sees is a shape entering, crossing, and leaving.
    public static func travel(alongWidth width: Double) -> ClosedRange<Double> {
        let half = length / 2
        return (-half)...(max(width, 0) + half)
    }

    /// Where the centre of the crest sits when nothing is moving.
    ///
    /// The head against the trailing edge, which is the end the next word lands at, with the whole
    /// tail behind it on the rule. That is what `Reduce Motion` draws and what every offscreen
    /// render photographs, and it is a mark in its own right rather than the figure caught mid
    /// stride: a directional shape parked at the end it points to.
    ///
    /// A rule narrower than one crest gets the crest centred instead, so the head does not run off
    /// an edge that is only a crest's length from where the tail began.
    public static func restingCentre(alongWidth width: Double) -> Double {
        let usable = max(width, 0)
        return usable - min(length, usable) / 2
    }

    /// The smallest whole number of wavelengths that covers a rule of this width, plus the one the
    /// train slides by. Never fewer than two, so the narrowest rule in the window still holds a
    /// crest and the trough behind it.
    public static func wavelengths(alongWidth width: Double) -> Int {
        max(2, Int((max(width, 0) / waveLength).rounded(.up)) + 1)
    }

    /// Cubic, and nothing cleverer. It is flat at both ends, which is what keeps a stop where the
    /// profile meets zero from showing as a crease in the gradient.
    private static func smoothstep(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
