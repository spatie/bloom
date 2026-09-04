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

    /// The same measurement, taking the last known answer when this pass cannot make one.
    ///
    /// **Nought is not a chrome, it is a pass that laid one of the two out and not the other**,
    /// which is what the negative case above answers nought for. Taken as a measurement it is
    /// worse than no answer at all: the cap it feeds is the room less the chrome less the floor
    /// the transcript keeps, so a chrome of nought hands the editor the whole of the chrome as
    /// well and the composer is allowed to squeeze the transcript past that floor.
    ///
    /// **A drag makes those passes constantly**, because the height the editor is being dragged to
    /// is written a frame before the composer holding it is measured at it, so the difference the
    /// chrome is taken from comes out negative on any frame the hand moves faster than the layout.
    /// The transcript is then given a height of nothing for a pass, and what a placement resolved
    /// against one does is `TranscriptAnchor.canPlace`: it parks the reader below the last row of
    /// the conversation, where nothing can bring them back.
    ///
    /// Nought until the first real measurement, which is what the caller starts from, so a
    /// composer that has never been laid out behaves exactly as it did before this existed.
    public static func chrome(_ height: CGFloat, knowing known: CGFloat) -> CGFloat {
        let measured = chrome(height)
        return measured > 0 ? measured : known
    }

    /// **The tallest the composer's editor may be drawn without taking the floor the transcript
    /// keeps.**
    ///
    /// The rule `ComposerView.maxEditorHeight` spelled inline, moved here because it is a decision
    /// and a decision taken inside a view is a decision nothing can test. Nothing about the
    /// arithmetic moved with it.
    ///
    /// **What it is worth testing is what happens when the chrome is wrong.** The floor is
    /// subtracted from the room along with the chrome, so a chrome that is short by its own whole
    /// value leaves the editor exactly the floor to eat into, and a real chrome is larger than the
    /// floor in a composer carrying chips. The transcript then has no height at all for that pass,
    /// which is the blank `TranscriptAnchor.canPlace` refuses to make permanent. See
    /// `chrome(_:knowing:)`, which is what keeps a drag from reporting one.
    ///
    /// A room of nought is a pane nobody has laid out rather than a pane with no room, so it is no
    /// cap at all: the editor takes its own height until there is a measurement to clamp it by.
    /// Nought means "not laid out yet" everywhere else in this file for the same reason.
    public static func editorCap(
        room: CGFloat, chrome: CGFloat, floor: CGFloat, atLeast line: CGFloat
    ) -> CGFloat {
        guard room > 0 else { return .greatestFiniteMagnitude }
        return max(room - chrome - floor, line)
    }
}
