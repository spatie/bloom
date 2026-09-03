import Foundation

/// Closing a review comment editor on text somebody has typed, and what they are asked first.
///
/// **The report this exists for: Cancel threw the sentence away on the press.** Both editors on a
/// diff, the one the gutter `+` opens and the one the pencil opens, closed on the click with no
/// question and no undo anywhere in the app that could bring the words back. Escape is the worse
/// half of it, because Escape is also how a menu, a popover and Quick Look are dismissed, so it
/// arrives at this box from a hand that was backing out of something else.
///
/// One question for both routes, and it is decided here rather than at each button, because two
/// wordings of one question drift and the only person who notices is the one being asked.
/// `PendingMessageDiscard` is the shape this follows: the decision and the sentences live where
/// the suite can read them, and only the dialog they are worn in belongs to the app.
public enum ReviewCommentDiscard: Equatable, Sendable {
    /// A comment being written for the first time. Closing loses the sentence outright.
    case writing
    /// A comment being rewritten in place. Closing keeps the comment and loses only the rewrite,
    /// which is the softer loss and still a loss: what goes is somebody's second thoughts about a
    /// note they had already decided to leave.
    case rewriting

    /// The question to ask before closing, or nil when there is nothing to lose and the editor
    /// should simply close.
    ///
    /// - Parameters:
    ///   - typed: what is in the field now.
    ///   - body: the comment being rewritten, or nil when one is being written for the first time.
    public static func needed(closing typed: String, replacing body: String?) -> Self? {
        // The judgement the confirm button is already offered on, asked once for both: a field
        // holding spaces and newlines is a field nobody has written in, and stopping to ask about
        // it would teach the owner to click through the question.
        guard ReviewCommentEdit.canSubmit(typed) else { return nil }
        guard let body else { return .writing }
        // Not `ReviewCommentEdit.outcome`, whose `unchanged` exists to stop a pointless write
        // invalidating every list reading the comments. That is a question about the store. This
        // one is about the reader, and text saying what the comment already says is text they
        // cannot lose by closing, however the store would have handled writing it.
        return ReviewCommentEdit.trim(typed) == ReviewCommentEdit.trim(body) ? nil : .rewriting
    }

    /// The one line a reader reliably reads. A question, ending in a question mark.
    public var title: String {
        switch self {
        case .writing: "Discard this comment?"
        case .rewriting: "Discard this rewrite?"
        }
    }

    /// What the answer does, said as consequences rather than as "are you sure?", because which
    /// of the two it is decides the answer: a comment that never reached the review and a note
    /// that keeps the words it already had are not the same loss.
    public var message: String {
        switch self {
        case .writing:
            "It is not added to the review, and its text is not kept."
        case .rewriting:
            "The comment keeps the text it already had, and the rewrite is not kept."
        }
    }

    public var confirmLabel: String { "Discard" }

    /// Named for what keeping means rather than "Cancel", which is the word on the button that
    /// asked the question and would read as undoing the question rather than answering it.
    public var cancelLabel: String {
        switch self {
        case .writing: "Keep Writing"
        case .rewriting: "Keep Editing"
        }
    }
}
