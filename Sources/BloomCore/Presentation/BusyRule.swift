import Foundation

/// The activity rule's figure: the hairline under the title bar, brightening and dimming while an
/// agent works.
///
/// It used to be a light travelling that rule, and what killed it was what it was made of. The
/// light was one point tall, in the accent colour, and it crossed a rule that is already the accent
/// at `restingOpacity`, so the mark was the same hue as the line it moved along. On pale chrome
/// there was nothing to see. Five ways out were drawn and animated side by side and the owner took
/// the plainest of them: no light and no travel, the whole width brightening at once, which is the
/// one variation that cannot be too small to notice because it is as wide as the window.
///
/// It moves on the busy dot's own wave rather than on a period of its own, so the rule and every
/// dot in the window swell together and the window has one heartbeat rather than two things
/// blinking near each other. `period` is the dot's number by construction and not by coincidence:
/// a second copy of it could only ever disagree with the first.
///
/// # Why the numbers live here
///
/// A view cannot be tested, so the shape of the motion is not a view's to own. What is here is the
/// envelope; what is left to the mark is turning it into a layer. `BusyDot` is the same split for
/// the dot this shares a wave with, and `BusyBreath` for the slower breath a retrying turn counts
/// down on.
public enum BusyRule {
    /// What the rule holds at the bottom of the pulse.
    ///
    /// It is also the whole of what the rule is under `Reduce Motion` and in an offscreen render,
    /// which is why it is a tint rather than nothing at all: the signal has to survive being
    /// frozen, and it has to be quiet enough that a still of a working window does not read as a
    /// rule drawn in the wrong colour. 0.32 is the number the travelling light rested at, kept
    /// because a screenshot of a busy window should not change on a branch that only replaced what
    /// moves.
    public static let restingOpacity = 0.32

    /// What it holds at the top: the accent, undiluted.
    ///
    /// The whole point of the change is that the mark is no longer a shade of the line it sits on,
    /// so the top of the pulse is the one place in this figure where holding anything back would
    /// put the old complaint straight back.
    public static let peakOpacity = 1.0

    /// One pulse: up, and back.
    ///
    /// The dot's, taken rather than restated. Every mark in the window phases off `BusyPulse.epoch`
    /// and that only puts them on one heartbeat while their periods stay in whole number ratios,
    /// and the strongest ratio available is one to one.
    public static var period: TimeInterval { BusyDot.period }

    /// Where the pulse begins, and therefore what is drawn when nothing is moving.
    public static let resting = 0.0

    /// How strongly the rule is drawn at a point in the pulse.
    ///
    /// A straight interpolation, because the easing is not this type's to hold: Core Animation is
    /// handed the two ends and a cubic timing function between them, the same way the dot's fade is.
    /// What this is for is the two ends themselves and the still figure, in one place, so retuning
    /// the mark is one edit rather than three.
    public static func opacity(at pulse: Double) -> Double {
        let fraction = min(max(pulse, 0), 1)
        return restingOpacity + (peakOpacity - restingOpacity) * fraction
    }
}
