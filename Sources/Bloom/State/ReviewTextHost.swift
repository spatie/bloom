import Observation
import BloomCore

/// Every character being typed into a review, kept away from everything that decides where those
/// characters are drawn.
///
/// The draft and the in-place edits used to be the text and the placement together, on
/// `WorkspaceModel`: `reviewDrafts[path]` held the spot, the anchor and the sentence so far, and
/// `reviewEdits[id]` held the rewritten body. Observation is per stored property and not per key,
/// so a keystroke invalidated every view that had read either dictionary for any reason.
/// `DiffView.body` reads both, for the spot the editor follows and for whether a band is open, so
/// each character typed re-ran the whole diff's body and rebuilt every row the lazy stack had
/// realised. On a diff of a few hundred visible lines that is a redraw per keystroke.
///
/// Split, the model keeps what `body` has to ask (which spot the editor is on, which comments are
/// open) and this object keeps what only the editor row itself reads. Typing now invalidates the
/// one text view it is being typed into.
///
/// It is an object rather than more state on the model for the reason `TranscriptHoverHost` is:
/// reaching it through a `let` registers no observation at all, so a view that only passes it on
/// pays nothing, and only the view that reads a key is invalidated when that key changes.
@MainActor
@Observable
final class ReviewTextHost {
    /// The comment being written on each file's diff, keyed by file path. Where it will attach is
    /// `WorkspaceModel.reviewDrafts`, and why either outlives the view is written down there.
    var drafts: [String: String] = [:]

    /// The text of every comment being edited in place, keyed by the comment it belongs to. Which
    /// ones are open is `WorkspaceModel.reviewEdits`.
    var edits: [ReviewCommentID: String] = [:]
}
