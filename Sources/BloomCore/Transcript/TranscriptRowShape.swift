import Foundation

/// What KIND of row a transcript entry is, for the one purpose of guessing how tall it will be.
///
/// **This exists because one running mean cannot serve rows of two different kinds, and the
/// reader's report is what a single one looks like.** `TranscriptRowHeights` settles its estimate
/// from the rows measured on arrival, and a pane arrives at the live end: the sample is the newest
/// answer, which is the longest prose in the session, next to a turn footer. Everything nobody has
/// looked at is then drawn at that number. Scrolling back is the window growing at the TOP, so a
/// screen of tool calls and folded runs from an hour ago is a screen of rows nobody has measured,
/// each of them told a prose height. A cell draws from its top down, so what the reader sees under
/// every one of them is blank: "still white gaps between output when I scroll up", reported
/// against 0.25.0 after the per-conversation estimate had already landed.
///
/// The estimate being per conversation was necessary and it was not sufficient. A conversation
/// does not have ONE row height. It has a handful of clusters, and which cluster a row is in is
/// known before anything is drawn.
///
/// ## Why these seven and not the eleven `MessageKind` has
///
/// A shape is a group of rows whose heights CLUSTER, not a restating of the message kinds. A tool
/// call and its result are drawn as one card and are the same size question; an error and a notice
/// are both a line or two in a box. Splitting those further divides the same evidence into smaller
/// samples and settles each of them later, which is the opposite of the point: what this buys is a
/// usable estimate from the three or four rows of a kind that ONE arrival screen provides.
///
/// **Where the grouping is drawn was measured rather than argued, and the first attempt was
/// wrong.** It had one `prose` case over everything anybody writes, on the reasoning above, and on
/// a walk up a 350 row conversation that halved the blank instead of removing it. What was left
/// was nearly all in that one case: a person's request is under a hundred points and much the same
/// length every time, an agent's answer is several hundred and varies by a factor of ten, and a
/// mean over both is a bad answer to both. Split into `message` and `answer`, the same walk went
/// from 24,972 points of blank to 9,387.
///
/// **A fold's line is the case that proves the grouping is worth having at all.** It is one line of
/// text with the same padding every time, so its height does not depend on the run it stands for,
/// and one measurement of one fold is the answer for every fold in the session. There is a fold
/// above nearly every turn in a long conversation, so a reader scrolling back meets more of them
/// than of anything else, and under a single conversation-wide mean every one of them was drawn at
/// the height of a paragraph.
///
/// It is a claim rather than a promise, exactly as `TranscriptRowInk` is. A row that turns out
/// unlike its shape reports its height when it is drawn and is corrected then, so being wrong here
/// costs one correction rather than a wrong transcript.
public enum TranscriptRowShape: Sendable, Hashable, CaseIterable {
    /// What somebody put IN: the owner's own message, or a note from another agent. Prose, but
    /// short prose, and much the same length every time, because a person types a request rather
    /// than a document.
    case message
    /// What came back: an answer or a thought, at the pane's reading measure. The tall end, and
    /// the one no scheme can predict, because two answers in one conversation differ by a factor
    /// of ten.
    case answer
    /// A call, its result, or the permission question drawn where the call would have been. One
    /// card, usually one line of it, because most of a session's tool rows are never opened.
    case tool
    /// The rule and the duration under a finished turn.
    case footer
    /// A line or two in a box: an error, a notice, the banner a session starts with.
    case notice
    /// The one line a folded run of a turn's working is drawn as.
    case fold
    /// A row this has nothing to say about: the four entries that are not stored rows, which are
    /// the setup log, the bubble on its way out, the streaming tail and a queued delivery. Each of
    /// them lives at the live end where it is measured before anything else, so a shape for them
    /// would buy nothing and could be wrong about the tail, which changes height without anything
    /// saying so.
    case other

    /// The shape of a stored row, from its kind alone.
    ///
    /// From the kind rather than from the payload, for the reason `TranscriptRowInk` gives: this
    /// is asked once per row on the pass that assembles the entries, and a decode there is the
    /// whole cost that pass exists not to pay.
    public static func of(kind: MessageKind) -> Self {
        switch kind {
        case .user, .crew: .message
        case .assistantText, .thinking: .answer
        case .toolUse, .toolResult, .permissionAsk: .tool
        case .result: .footer
        case .error, .notice, .system: .notice
        }
    }
}
