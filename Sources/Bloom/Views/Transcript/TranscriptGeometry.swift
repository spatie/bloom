import Foundation

/// What the transcript needs to know about the space it is being drawn in.
///
/// Both values come from one `onScrollGeometryChange` subscription rather than from a
/// `GeometryReader` and a preference key: the scroll view already knows its container size, its
/// content size and where it sits between them, and asking it directly is both cheaper and immune
/// to the "the probe stopped being built" edge cases a preference-based measurement has.
///
/// **It holds the bubble cap rather than the width it was worked out from, and that is a
/// performance decision rather than a tidiness one.** This value is `@State` in `TranscriptListView`,
/// so every change to it re-runs that view's body and with it the `ForEach` over every row the
/// lazy stack has realised. A raw container width changes on every pixel of a sidebar drag, which
/// is once a frame, for a number whose only use is capping the width of a speech bubble. Rounded
/// to `step`, it changes about once every eleven points instead, and the drag stops rebuilding the
/// list to move a bubble's edge by one point.
struct TranscriptGeometry: Equatable {
    /// The widest a user bubble may be, already rounded. Not the container width: see above.
    var bubbleCap: CGFloat = 240
    /// Whether the user is close enough to the newest row to count as following along.
    var isNearBottom = true

    /// The quantum the cap is rounded to. Eight points is invisible on a bubble that is several
    /// hundred wide, and small enough that a pane resized by hand still ends up with a bubble that
    /// looks like it fits the pane.
    ///
    /// Rounded DOWN rather than to nearest, so the cap can never come out wider than the share of
    /// the pane it is meant to be.
    static let step: CGFloat = 8

    static func cap(width: CGFloat, share: CGFloat, gutter: CGFloat, floor: CGFloat) -> CGFloat {
        let raw = max(floor, (width - gutter * 2) * share)
        return (raw / step).rounded(.down) * step
    }
}
