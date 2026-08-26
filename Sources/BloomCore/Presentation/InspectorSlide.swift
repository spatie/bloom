import CoreGraphics
import Foundation

/// The inspector's slide, sampled: how wide the title bar's trailing end is part way through it.
///
/// The inspector arriving or leaving moves three things, and two of them are drawn by frameworks
/// that cannot see each other. The pane is an `NSSplitViewItem` under AppKit's animator. The pull
/// request band is SwiftUI, in a title bar accessory. And the accessory's own width is what is
/// left over for the toolbar, so the search field at the toolbar's trailing end sits exactly where
/// the accessory's leading edge puts it: measured offscreen at 1440 points with a 380 point
/// accessory, the field's capsule lands at x=727, hard against the band. Take the accessory away
/// and the field has 379 more points to pack into.
///
/// That is the bug this exists for. The accessory used to jump between one point and 380 in a
/// single frame, so the field popped to its new x while the pane spent a quarter of a second
/// sliding under it. Nothing in AppKit animates a toolbar item's position for you, and nothing
/// needs to: an `NSToolbar` re-packs its items whenever the space it is given changes, which is
/// what it does on every frame of a live window resize. Give it a width that moves and the field
/// moves with it.
///
/// So the accessory is stepped by hand, off a display link, and this is the arithmetic of that
/// step. It is here rather than in the controller because a curve chosen inside a view is a curve
/// nothing can test, and because the number it produces has to agree with two animations it cannot
/// see: `ease` below is the same cubic `CAMediaTimingFunction(name: .easeInEaseOut)` and SwiftUI's
/// `.easeInOut` are, so all three halves of one movement are on one curve as well as one length.
public struct InspectorSlide: Equatable, Sendable {
    /// The width the title bar's trailing end had when the slide started, which is wherever it had
    /// got to if the last one was reversed halfway.
    public let from: CGFloat

    /// The width it is going to: the pane's own, or one point for a pane that is leaving. Never
    /// zero. A title bar accessory of no size at all is a view the title bar's layout can drop.
    public let to: CGFloat

    /// How long the whole movement takes. `Motion.inspectorSeconds` at every call site, which is
    /// also what the split view's animation context is given.
    public let seconds: TimeInterval

    public init(from: CGFloat, to: CGFloat, seconds: TimeInterval) {
        self.from = from
        self.to = to
        self.seconds = seconds
    }

    /// The width to give the accessory this frame.
    ///
    /// `elapsed` is measured against the frame being drawn rather than against now, because the
    /// two animations this has to agree with are interpolated at presentation time and a callback
    /// that reads the clock when it fires runs a frame behind them. See `CADisplayLink.targetTimestamp`.
    public func width(after elapsed: TimeInterval) -> CGFloat {
        guard seconds > 0, elapsed > 0 else { return elapsed > 0 ? to : from }
        guard elapsed < seconds else { return to }
        return from + (to - from) * CGFloat(Self.ease(elapsed / seconds))
    }

    /// Whether the display link driving this has anything left to do.
    ///
    /// A slide with no length, and an elapsed time that is not a number, both finish immediately.
    /// The alternative to answering true for those is a display link that never stops, which is a
    /// layout pass per frame for the rest of the window's life.
    public func hasFinished(after elapsed: TimeInterval) -> Bool {
        guard seconds > 0 else { return true }
        return !(elapsed < seconds)
    }

    // MARK: - The curve

    /// `easeInEaseOut`, which is the cubic bezier through (0.42, 0) and (0.58, 1).
    ///
    /// Spelled out here rather than borrowed from either framework because it has to be the same
    /// one in both: Core Animation names it `kCAMediaTimingFunctionEaseInEaseOut` and SwiftUI
    /// names it `.easeInOut`, and both are these four numbers. A curve of our own here, however
    /// close, would put the band's leading edge and the search field a few points apart in the
    /// middle of every slide, which is the seam this whole file exists to close.
    ///
    /// The y polynomial with those controls reduces to `3t^2 - 2t^3`, so the only real work is
    /// solving x for t, which is Newton-Raphson with a bisection to fall back on.
    public static func ease(_ fraction: Double) -> Double {
        guard fraction > 0 else { return 0 }
        guard fraction < 1 else { return 1 }

        var t = fraction
        for _ in 0..<8 {
            let error = sampleX(t) - fraction
            if abs(error) < tolerance { return sampleY(t) }
            let slope = derivativeX(t)
            if abs(slope) < tolerance { break }
            t -= error / slope
        }

        var low = 0.0
        var high = 1.0
        t = fraction
        for _ in 0..<32 {
            let value = sampleX(t)
            if abs(value - fraction) < tolerance { break }
            if value < fraction { low = t } else { high = t }
            t = (low + high) / 2
        }
        return sampleY(t)
    }

    private static let tolerance = 1e-6

    /// The first control point's x, which is the whole of the ease in.
    private static let firstX = 0.42
    /// The second control point's x. The two y values are 0 and 1 and are folded into `sampleY`.
    private static let secondX = 0.58

    private static var coefficientC: Double { 3 * firstX }
    private static var coefficientB: Double { 3 * (secondX - firstX) - coefficientC }
    private static var coefficientA: Double { 1 - coefficientC - coefficientB }

    private static func sampleX(_ t: Double) -> Double {
        ((coefficientA * t + coefficientB) * t + coefficientC) * t
    }

    private static func derivativeX(_ t: Double) -> Double {
        (3 * coefficientA * t + 2 * coefficientB) * t + coefficientC
    }

    private static func sampleY(_ t: Double) -> Double {
        t * t * (3 - 2 * t)
    }
}
