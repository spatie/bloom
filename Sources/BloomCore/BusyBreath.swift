import Foundation

/// The breath a slow mark in Bloom moves on: the glyph on a retrying turn, which fades in and out
/// while the delay runs down.
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
/// envelope; what is left to the mark is what it drives. `BusyDot` is the same split for the
/// quicker pulse every busy mark moves on. The tests assert the shape (bounded, asymmetric,
/// resting at the bottom, arriving at the top) rather than the literals, so the curve can be
/// retuned without rewriting them.
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
    /// rule and the marks in the sidebar are one heartbeat rather than two that drift past each
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

    /// What the mark holds at the bottom of the breath.
    ///
    /// Not nothing, for the reason `BusyDot` gives for its own floor: a glyph that reaches zero is
    /// absent for part of every cycle, and a thirteen point symbol in a reading column is glanced
    /// at rather than watched. A mark that disappears and comes back reads as a fault.
    public static let restingOpacity = 0.45

    /// The opacity a breathing mark is drawn at, at a fraction of the period.
    ///
    /// The envelope is here rather than at the mark for the reason the rest of this type is: the
    /// retry glyph used to hold these two numbers itself, inside a `keyframeAnimator`, where
    /// nothing could ask what they were.
    public static func opacity(atPhase phase: Double) -> Double {
        restingOpacity + (1 - restingOpacity) * value(atPhase: phase)
    }

    /// The opacities of one whole breath, for a `CAKeyframeAnimation` that interpolates between
    /// them. The last repeats the first, so the animation closes on itself.
    public static func opacitySamples(count: Int = 48) -> [Double] {
        samples(count: count).map { restingOpacity + (1 - restingOpacity) * $0 }
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
}
