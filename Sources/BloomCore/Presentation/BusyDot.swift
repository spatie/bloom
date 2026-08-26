import Foundation

/// The pulse every busy mark in Bloom is made of: one dot, swelling and fading.
///
/// Three places draw it. The transcript sets it beside "Requesting" and "Working" when the agent
/// has not said anything yet, a tab whose agent is mid turn carries it in front of its label, and
/// it is the mark at the head of a running sidebar row. One figure rather than three, because the
/// sidebar used to draw a pair of breathing rings instead and a window that says "this is working"
/// in two different shapes is a window that has to be learned twice.
///
/// It swells and dims together, so the mark gains size as it loses weight and its area of ink is
/// roughly constant. And it never goes out: the low end of the fade is half strength, not nothing,
/// because a mark that reaches zero is absent for part of every cycle, and a column of thirteen
/// point glyphs is read at a glance rather than watched.
///
/// # Why the numbers live here
///
/// A view cannot be tested, so the shape of the motion is not a view's to own. What is here is the
/// envelope and the two quantities it drives; what is left to the mark is turning them into a
/// layer. `BusyBreath` is the same split, for the slower breath the retry row counts down on.
public enum BusyDot {
    /// One pulse: out, and back.
    ///
    /// A second and a half, where the SwiftUI animation this replaced ran 0.7 seconds each way.
    /// Every moving mark in the window takes its phase from `BusyPulse.epoch` so that the window
    /// has one heartbeat rather than several that drift past each other, and that only holds while
    /// the periods stay in whole number ratios. This is the number the rest are measured against:
    /// the rule under the title bar takes it outright (`BusyRule.period`), so the rule and every
    /// dot reach the top of their pulse on the same frame, and a breath is 3 seconds, which is two
    /// of these. 1.4 divides neither, and the marks would beat against each other rather than
    /// share a beat. Each leg is therefore a twentieth of a second longer than it was, which is
    /// not a difference anybody can see.
    public static let period: TimeInterval = 1.5

    /// How wide the dot is at the top of its pulse, as a multiple of its resting diameter.
    public static let peakScale = 1.35

    /// What it holds at the top, where the resting figure holds all of it.
    public static let peakOpacity = 0.5

    /// Where the figure sits when nothing is moving: full size and full strength.
    ///
    /// Not half way, unlike the rings this replaced. The still dot has to be a mark in its own
    /// right, because it is what `Reduce Motion` draws and what an offscreen render photographs,
    /// and a dot held mid pulse is a dot somebody would read as faded rather than as still.
    public static let resting = 0.0

    /// How wide the dot is at a point in the pulse, as a multiple of its resting diameter.
    public static func scale(at pulse: Double) -> Double {
        interpolated(from: 1, to: peakScale, at: pulse)
    }

    /// What it holds at that point.
    public static func opacity(at pulse: Double) -> Double {
        interpolated(from: 1, to: peakOpacity, at: pulse)
    }

    /// The diameter the dot's path is built at, as a multiple of its resting diameter.
    ///
    /// Its largest, so the figure is only ever scaled down. A filled circle resampled smaller
    /// keeps a clean edge; one scaled past the size its path was built at softens, which at six
    /// points reads as a focus problem. The rings this mark replaced were baked the same way, and
    /// were measured doing it: a stroke scaled up thickened and softened where one scaled down
    /// only thinned.
    public static var drawnScale: Double { peakScale }

    /// Where the layer's scale sits at a point in the pulse, given a path built at `drawnScale`.
    public static func pathScale(at pulse: Double) -> Double {
        scale(at: pulse) / drawnScale
    }

    private static func interpolated(from: Double, to: Double, at fraction: Double) -> Double {
        from + (to - from) * min(max(fraction, 0), 1)
    }
}
