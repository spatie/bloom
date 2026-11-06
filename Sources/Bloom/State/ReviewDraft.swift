import BloomCore

/// A review comment mid-composition: where it will attach and the evidence captured when its
/// editor opened. See `WorkspaceModel.reviewDrafts` for why it outlives the diff view that is
/// editing it, and `ReviewTextHost` for why the text it is being given is not in here.
struct ReviewDraft: Hashable {
    /// Every line the note will cover, which is one line for a `+` pressed and several for a
    /// drag down the gutter.
    var selection: ReviewSelection
    var anchor: ReviewCommentAnchor

    /// Where the note anchors, which is also the row the editor opens under when the selection is
    /// a single line.
    var spot: ReviewSpot { selection.anchor }
}
