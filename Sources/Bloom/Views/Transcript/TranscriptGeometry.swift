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
    /// How tall the pane is, rounded down to `heightStep`, for the one thing in the transcript
    /// that is sized as a share of it: the running setup tail. See `SetupTailWindow`.
    ///
    /// Rounded for the same reason the bubble cap is, and to a coarser step because it can afford
    /// one. It feeds a line count, and at half the pane it takes two lines of pane height to buy
    /// one line of tail, so anything finer than a line of tail is a rebuild of every realised row
    /// for a number that has not changed. Nought until the pane is measured, which
    /// `SetupTailWindow.cap` reads as "not laid out yet" rather than as "no room".
    var paneHeight: CGFloat = 0
    /// Whether the user is close enough to the newest row to count as following along.
    var isNearBottom = true

    /// The quantum the cap is rounded to. Eight points is invisible on a bubble that is several
    /// hundred wide, and small enough that a pane resized by hand still ends up with a bubble that
    /// looks like it fits the pane.
    ///
    /// Rounded DOWN rather than to nearest, so the cap can never come out wider than the share of
    /// the pane it is meant to be.
    static let step: CGFloat = 8

    /// The quantum the pane height is rounded to. See `paneHeight`: about two lines of the face
    /// the setup tail is set in, which is what it takes to change the answer by one line.
    static let heightStep: CGFloat = 32

    static func cap(width: CGFloat, share: CGFloat, gutter: CGFloat, floor: CGFloat) -> CGFloat {
        let raw = max(floor, (width - gutter * 2) * share)
        return (raw / step).rounded(.down) * step
    }

    /// Rounded DOWN, like the cap above, so a share worked out from this can never come out taller
    /// than the share of the pane it is meant to be. Never below one step while there is a pane at
    /// all, because nought is reserved for the pane that has not been laid out and a divider
    /// dragged to the floor is not that.
    static func height(_ height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return max(heightStep, (height / heightStep).rounded(.down) * heightStep)
    }
}
