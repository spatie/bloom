import Foundation

/// The figure a busy tab, or a busy column with no strip, is drawn with: Safari's loading sweep.
///
/// # Why this, after two that did not work
///
/// A crest under each busy tab was reported as sitting underneath the tab rather than being part
/// of it, and the same crest along the column's top edge as a hard full width blue line. A shimmer
/// through the busy name followed, and the owner's report on that was that it was too subtle in
/// both places, and that a short name leaves too little text for a band to be seen crossing.
///
/// So the tab itself moves now, whatever its name. **With a strip**, a soft band of house blue
/// sweeps through the tab's capsule from the leading edge to the trailing one, behind the icon and
/// the label, and a busy tab that is not selected gets a faint blue capsule of its own for the band
/// to live in. **With no strip**, a short segment slides along the top of the column, under the
/// title bar, with nothing drawn behind it: no lit track, which is what the hard line was.
///
/// Every number is the owner's chosen mockup, restated so it can be tested. `BusySignalPlacement`
/// decides which of the two is drawn, and `BusySweepView` in the app is how.
public enum BusySweep {
    /// One crossing, from wholly off the leading edge to wholly off the trailing one.
    public static let period: TimeInterval = 1.6

    /// The crossing's pace, as the control points of a cubic bezier: the mockup's
    /// `cubic-bezier(.45, .05, .55, .95)`. Slow to leave, quick through the middle, slow to arrive,
    /// which is what makes it read as Safari's rather than as a conveyor belt.
    public static let curve = (x1: 0.45, y1: 0.05, x2: 0.55, y2: 0.95)

    /// How long the sweep takes to arrive and to leave.
    ///
    /// A turn ends at any moment, including with the band halfway across, and a band that vanishes
    /// between two frames is a pop. A quarter of a second reads as a light going out and is short
    /// enough not to claim work that has already stopped.
    public static let fade: TimeInterval = 0.25

    /// The most frames a second the render server is asked for while a band moves.
    ///
    /// Sixty rather than a ProMotion panel's hundred and twenty, which is the cap `ActivityRule`
    /// measured and settled on: the column's segment is the fastest thing here, 760 points plus its
    /// own width in 1.6 seconds, about 640 points a second on average and 1.73 times that through
    /// the middle of the ease. Sixty frames puts the fastest step at about 18 points, against a soft
    /// ramp of 80 at each end of a 266 point segment, which is inside the softness of the edge
    /// doing the moving. `BusySweepTests.stepsInsideTheRamp` holds that arithmetic.
    public static let frameRate = 60.0

    /// How much faster than its average the crossing moves at its fastest, which for this curve is
    /// its middle: the slope of the bezier at half way through.
    public static var peakSpeedFactor: Double {
        let t = 0.5
        func derivative(_ p1: Double, _ p2: Double) -> Double {
            3 * ((1 - t) * (1 - t) * p1 + 2 * (1 - t) * t * (p2 - p1) + t * t * (1 - p2))
        }
        return derivative(curve.y1, curve.y2) / derivative(curve.x1, curve.x2)
    }

    // MARK: The two figures

    /// One gradient carried across a track, in widths of that track.
    ///
    /// Stated in widths rather than points so a tab that changes size, in a window being resized or
    /// a strip gaining a tab, needs its layers resized and nothing else: the animation's own values
    /// do not depend on the width. See `anchor(atLeadingEdge:)`.
    public struct Band: Equatable, Sendable {
        /// How wide the band is, as a share of the track.
        public let widthShare: Double
        /// Where the band's leading edge is when a crossing begins, in track widths.
        public let leadingFrom: Double
        /// Where the band's leading edge is when a crossing ends, in track widths.
        public let leadingTo: Double
        /// The gradient along the band, leading to trailing, as the share of the band's full
        /// strength at each location.
        public let stops: [Stop]

        public init(widthShare: Double, leadingFrom: Double, leadingTo: Double, stops: [Stop]) {
            self.widthShare = widthShare
            self.leadingFrom = leadingFrom
            self.leadingTo = leadingTo
            self.stops = stops
        }

        /// Where the leading edge is at a point through the crossing, from 0 to 1, after the
        /// easing: the caller hands in eased progress, which is Core Animation's to compute.
        public func leadingEdge(at progress: Double) -> Double {
            leadingFrom + (leadingTo - leadingFrom) * progress
        }

        /// The layer anchor that puts the leading edge there, for a band layer positioned at the
        /// track's leading edge.
        ///
        /// **This is the whole of why a resize does not restart the sweep.** A layer's anchor is
        /// measured in its own widths, so with the layer's position pinned to the track's leading
        /// edge its leading edge sits at `-anchor * bandWidth`, and `bandWidth` is `widthShare` of
        /// the track. Animating the anchor from one value to another moves the band the same share
        /// of the track at any width, so a tab growing mid crossing keeps its band where it was,
        /// proportionally, with no animation rebuilt. Animating `position.x` would bake the width
        /// into the animation and need reinstalling on every frame of a window drag.
        public func anchor(atLeadingEdge leading: Double) -> Double {
            -leading / widthShare
        }

        /// The furthest a band's visible part reaches onto the track at the start of a crossing,
        /// and the nearest it comes at the end, in track widths. A stop at zero strength draws
        /// nothing, so only the stops that draw count.
        public var visibleReach: (atStart: Double, atEnd: Double) {
            let drawn = stops.filter { $0.strength > 0 }.map(\.location)
            let first = drawn.min() ?? 0
            let last = drawn.max() ?? 1
            return (leadingFrom + last * widthShare, leadingTo + first * widthShare)
        }
    }

    /// One point along a band's gradient.
    public struct Stop: Equatable, Sendable {
        public let location: Double
        public let strength: Double

        public init(location: Double, strength: Double) {
            self.location = location
            self.strength = strength
        }
    }

    /// The band through a busy tab's capsule.
    ///
    /// The mockup's CSS, translated: a background 55 per cent of the tab wide, its
    /// `background-position` running from -120 per cent to 220. A percentage position in CSS is
    /// measured against the room the image leaves, which is 45 per cent of the tab, so the leading
    /// edge travels from -0.54 of the tab to 0.99. At -0.54 the band's trailing edge is a hundredth
    /// inside the tab, and that hundredth is the transparent end of the gradient, so what is seen
    /// is a band entering from nothing and leaving to nothing.
    public static let tab = Band(
        widthShare: 0.55,
        leadingFrom: -1.2 * (1 - 0.55),
        leadingTo: 2.2 * (1 - 0.55),
        stops: [
            Stop(location: 0, strength: 0),
            Stop(location: 0.45, strength: 1),
            Stop(location: 0.55, strength: 1),
            Stop(location: 1, strength: 0),
        ]
    )

    /// The segment along the top of a column with no strip: 35 per cent of the column, solid from
    /// 30 to 70 per cent of itself, slid from `left: -35%` to `left: 100%`.
    public static let column = Band(
        widthShare: 0.35,
        leadingFrom: -0.35,
        leadingTo: 1,
        stops: [
            Stop(location: 0, strength: 0),
            Stop(location: 0.3, strength: 1),
            Stop(location: 0.7, strength: 1),
            Stop(location: 1, strength: 0),
        ]
    )

    /// How tall the column's segment is, in points. Its ends are rounded to half of this.
    public static let columnThickness = 2.5

    // MARK: Strengths

    /// An opacity of `PaletteInk.accentFill`, per appearance.
    ///
    /// The house fill is one value in both appearances, and a blue at a given opacity over dark
    /// chrome is a much smaller step than the same opacity over white. So every tint here has a
    /// dark member of its own, and each was set by measuring rather than by eye: the dark member is
    /// the least opacity whose composite is at least as far from its ground, by CIEDE2000, as the
    /// light member's composite is from its own. `PaletteContrastTests.theSweepReads` holds that,
    /// and holds the label drawn over each at the text floor.
    public struct Strength: Equatable, Sendable {
        public let light: Double
        public let dark: Double

        public init(light: Double, dark: Double) {
            self.light = light
            self.dark = dark
        }

        public func member(dark isDark: Bool) -> Double { isDark ? dark : light }
    }

    /// The tab band at its peak. Light is the mockup's 34 per cent: 16.0 from the white capsule.
    /// Dark at 0.34 measured 10.7 from the dark capsule, two thirds of that, and 0.55 is 16.8.
    public static let tabBand = Strength(light: 0.34, dark: 0.55)

    /// The faint capsule under a busy tab that is not selected. Light is the mockup's 8 per cent,
    /// 3.8 from the strip. Dark at 0.08 measured 2.6, and 0.12 only 3.7; 0.14 is 4.4.
    public static let tabWash = Strength(light: 0.08, dark: 0.14)

    /// What Reduce Motion lays over the selected capsule of a busy tab, which has no band to say
    /// it. A little stronger than the wash, because a white capsule already reads as the selection
    /// and a tint as faint as the wash on it is lost in the glass.
    public static let tabStill = Strength(light: 0.12, dark: 0.2)

    /// The top of the column's still wash under Reduce Motion, fading to nothing over
    /// `columnStillHeight`. Light is 7.1 from the window's ground, and dark at 0.22 is the same.
    public static let columnStill = Strength(light: 0.14, dark: 0.22)

    /// How far down the column the still wash reaches before it has faded out, in points.
    ///
    /// **A wash rather than a line, on purpose.** Reduce Motion takes the segment's movement away,
    /// and a still 2.5 point bar in its place is the hard full width blue line the owner reported
    /// the crest as, drawn again. A glow falling off from the top edge is a region, not a rule: it
    /// tints the top of the column the way the busy tab's wash tints a capsule.
    public static let columnStillHeight = 20.0
}
