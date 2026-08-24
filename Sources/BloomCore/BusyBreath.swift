import Foundation

/// The breath a slow mark in Bloom moves on, and the two rings the sidebar draws with it.
///
/// Four stretches, not two, and deliberately not a sine: an inhale that fills quickly and settles,
/// a short hold at the top, a longer exhale that drops and then trails, and a real pause at the
/// bottom. That asymmetry is the whole difference between breathing and pulsing. A sine spends
/// equal time going each way, so it reads as a status light however slowly it is run, which is what
/// seventeen candidates drawn side by side in a browser were used to establish before any of this
/// was written in Swift.
///
/// # Why the numbers live here
///
/// A view cannot be tested, so the shape of the motion is not a view's to own. What is here is the
/// envelope and the geometry it drives; what is left to the mark is turning them into layers. The
/// tests assert the shape (bounded, asymmetric, resting at the bottom, arriving at the top) rather
/// than the literals, so the curve can be retuned without rewriting them.
public enum BusyBreath {
    /// Fractions of one period. They sum to one, and the remainder after the three named stretches
    /// is the rest at the bottom.
    public static let inhale = 0.32
    public static let held = 0.10
    public static let exhale = 0.44

    /// The pause at the bottom, where the figure is at rest and nothing moves.
    public static var rest: Double { 1 - inhale - held - exhale }

    /// How long one breath takes.
    ///
    /// Three seconds, and the third decimal matters. The design was drawn at 3.6, which is inside
    /// the 3.0 to 3.8 band every breathing candidate was drawn in, and 3.6 was not kept. Every
    /// moving mark in this window reads its phase from `BusyPulse.epoch` so that the light on the
    /// rule and the figures in the sidebar are one heartbeat rather than two that drift past each
    /// other, and that only holds while the periods stay in whole number ratios: the rule crosses
    /// in 3 seconds and its whole figure is 6. A 3.6 second breath shares no useful multiple with
    /// either, so the two marks would beat against each other on a cycle of half a minute. Three
    /// seconds is exactly one crossing of the rule, so a breath and a crossing begin together
    /// every time.
    public static let period: TimeInterval = 3

    /// Where the breath is at a fraction of its period, from 0 at rest to 1 at the top.
    ///
    /// The inhale is eased out hard (an exponent well above 1) so the figure arrives rather than
    /// creeps, and the exhale is eased more gently so it falls and then trails. Anything outside
    /// 0 to 1 wraps, which is what lets a caller hand this an absolute time.
    ///
    /// Both powers take a base clamped to nought or above. Rounding puts the base a hair below zero
    /// at the far end of a stretch, and `pow` of a negative base with a fractional exponent is not a
    /// number, which propagates silently into a layer transform as a figure that vanishes. Found by
    /// a test sweeping the period rather than by watching it happen.
    public static func value(atPhase phase: Double) -> Double {
        let p = phase - phase.rounded(.down)
        if p < inhale {
            return 1 - pow(max(0, 1 - p / inhale), 2.5)
        }
        if p < inhale + held {
            return 1
        }
        if p < inhale + held + exhale {
            return pow(max(0, 1 - (p - inhale - held) / exhale), 1.55)
        }
        return 0
    }

    /// The breath sampled evenly across one period, for a keyframe animation.
    ///
    /// Sampled rather than expressed as four keyframes with timing functions, because the two eased
    /// stretches are power curves and Core Animation's timing functions are cubic beziers: fitting
    /// them would be an approximation of an approximation. At the default count the samples are
    /// under a tenth of a second apart, and the value moves less than a twentieth of its range
    /// between neighbours, so linear interpolation between them is invisible.
    ///
    /// The last sample repeats the first, so a repeating animation closes on itself.
    public static func samples(count: Int = 48) -> [Double] {
        precondition(count > 1, "a breath needs at least two samples")
        return (0...count).map { value(atPhase: Double($0) / Double(count)) }
    }

    /// The sidebar's running mark: two concentric rings whose radial gap breathes.
    ///
    /// The inner ring grows while the outer shrinks, until they almost meet, and then they part
    /// again. It is the one candidate of seventeen where the motion is between two elements rather
    /// than inside either, which is why it survived: at thirteen points a single element changing
    /// size is a dot getting bigger, and two elements approaching each other is a gesture.
    public enum Rings {
        /// The inner ring, at rest and at the top of the breath.
        public static let inner: ClosedRange<Double> = 1.8...3.5

        /// The outer ring, at rest and at the top of the breath. It shrinks as the inner grows, so
        /// the value at the top of the breath is the smaller one.
        public static let outer: ClosedRange<Double> = 3.9...5.6

        /// What the outer ring holds. It brightens a little as it closes in, so the pair reads as
        /// one figure tightening rather than as a fixed ring with something moving inside it.
        public static let outerOpacity: ClosedRange<Double> = 0.5...0.75

        /// What the inner ring holds, throughout. It is the mark's own weight and does not move:
        /// the figure must never go out, because a mark that goes dark is a different shape twice a
        /// beat and the shape is what this column is read by.
        public static let innerOpacity = 0.95

        /// The radius each ring is drawn at, before any scaling.
        ///
        /// Each is baked at its largest and scaled down, never up, so a stroke is only ever
        /// resampled thinner than it was drawn. A ring scaled past the size its path was built at
        /// would thicken and soften, which at this size looks like a focus problem.
        public static var innerDrawn: Double { inner.upperBound }
        public static var outerDrawn: Double { outer.upperBound }

        /// Where a ring sits at a point in the breath, as a fraction of the radius it was drawn at.
        public static func innerScale(at breath: Double) -> Double {
            interpolated(inner, at: breath) / innerDrawn
        }

        /// The outer ring runs the other way: it is widest at rest.
        public static func outerScale(at breath: Double) -> Double {
            interpolated(outer, at: 1 - breath) / outerDrawn
        }

        public static func outerOpacity(at breath: Double) -> Double {
            interpolated(outerOpacity, at: breath)
        }

        private static func interpolated(_ range: ClosedRange<Double>, at fraction: Double) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * min(max(fraction, 0), 1)
        }
    }
}
