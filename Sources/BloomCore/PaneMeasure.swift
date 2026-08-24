import Foundation

/// A measured pane dimension, rounded to a step before anything holds on to it.
///
/// **This is the rule `TranscriptGeometry` wrote down, applied to the rest of the centre column.**
/// A container's height arrives from `onGeometryChange` on every pixel of a window or divider
/// drag, which is once a frame. Kept raw in `@State` it re-runs the body that holds it, and in the
/// centre column that body is the whole chat pane: the transcript's list, every row it has
/// realised, and the composer under it. Rounded to `step` it changes about once every eight
/// points instead, and a drag stops rebuilding a pane to move a clamp by one point.
///
/// It is only ever worth doing where the number is used for something coarse. Both callers here
/// are exactly that: `ChatPaneView.conversationHeight` and `ComposerView.chromeHeight` meet in
/// `ComposerView.maxEditorHeight`, which decides how far the composer may be dragged before the
/// transcript is squeezed, and a point either way there is invisible.
public enum PaneMeasure {
    /// The quantum. Eight points, the same as `TranscriptGeometry.step`, which is under a line of
    /// the face the composer is set in and so cannot move the clamp by anything a reader sees.
    public static let step: CGFloat = 8

    /// Rounded DOWN, so a value worked out from this can never come out larger than the room
    /// actually measured. Never below one step while there is a pane at all, because nought is
    /// reserved for "not laid out yet, no cap" and a pane dragged to a sliver is not that. See
    /// `TranscriptGeometry.height`, which is the same rule for the same reason.
    public static func room(_ height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return max(step, (height / step).rounded(.down) * step)
    }

    /// Rounded UP, for a measurement that is SUBTRACTED from the room. Erring upwards on the
    /// chrome and downwards on the room both leave the editor a little less space than it could
    /// have had, which is the safe direction: the transcript keeps its floor either way.
    ///
    /// Negative is nought. The chrome is a difference between two measurements taken in the same
    /// pass, and a pass that has laid out one of them and not the other can report the editor as
    /// taller than the composer holding it.
    public static func chrome(_ height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return (height / step).rounded(.up) * step
    }
}
