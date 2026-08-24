import Foundation

/// What confirming an in-place edit of a review comment means.
///
/// The band that draws a pending comment has an edit control beside its remove control, and the
/// three questions that control raises are not questions a view can answer where anything could
/// check the answer: whether the typed text is worth writing, what an emptied field means, and
/// which characters actually reach the store. So they are answered here and the band calls this.
///
/// The rules are the ones writing a comment already follows, said once for both paths. Writing
/// trims the body and refuses an empty one (`DiffView.commitDraft` throws the draft away rather
/// than minting a blank comment), so editing trims the same way and refuses the same way. The
/// alternative, reading an emptied field as "delete this comment", was rejected: the band's own
/// remove control is one point away, it asks for no typing, and a person who selects all and
/// presses Return in a text field is far more likely to have made a mistake than to have chosen
/// the destructive path. A refusal costs them one Escape; the other reading costs them the
/// comment.
public enum ReviewCommentEdit {
    /// What the caller should do with what was typed.
    public enum Outcome: Sendable, Hashable {
        /// Write this body. Already trimmed, so the store never sees the edges.
        case save(String)
        /// The text says what the comment already says. Close the editor and write nothing: an
        /// identical write is still a write, and every list reading the comments is invalidated
        /// by one.
        case unchanged
        /// Nothing to save. The comment keeps the body it has and the editor stays open, because
        /// the only way to reach this is an empty field and the text that was there is the thing
        /// most worth not throwing away.
        case refused
    }

    /// Whitespace at the edges is not content. It is what a paste brings with it and what a
    /// half-deleted line leaves behind, and a body carrying it renders as a comment with a blank
    /// first line in the prompt payload. Interior line breaks are content and are kept.
    public static func trim(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the confirm control is worth offering at all, which is the same question as
    /// whether the outcome would be a refusal.
    public static func canSubmit(_ typed: String) -> Bool {
        !trim(typed).isEmpty
    }

    /// - Parameters:
    ///   - typed: what is in the field now.
    ///   - body: the comment's stored body.
    public static func outcome(typed: String, replacing body: String) -> Outcome {
        let trimmed = trim(typed)
        guard !trimmed.isEmpty else { return .refused }
        guard trimmed != body else { return .unchanged }
        return .save(trimmed)
    }
}
