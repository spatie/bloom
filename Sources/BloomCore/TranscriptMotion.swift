import Foundation

/// What the transcript is allowed to fade in.
///
/// Three different things get called "text appearing in the chat window" and they do not want the
/// same treatment, so the rules for telling them apart live here rather than inside a view where
/// nothing could test them.
///
/// **A row landing in the list fades.** A tool call, a result, a turn footer, a notice. It lands
/// where a "Running Bash" line was and it reads better as a settle than as a pop. `fadesOnArrival`
/// is that rule, and `RowArrival` in the app is the mechanism.
///
/// **A block of streamed prose fades once, when the block first has anything in it.** Not per
/// delta. A delta is a handful of characters arriving many times a second, and a fade started on
/// each one is a shimmer at the tail of the answer, which is a good deal worse than the pop it
/// would be replacing. So the fade belongs to the block rather than to the text, and there is
/// nothing here to decide per delta: see `StreamingRowView`.
///
/// **A session's history does not fade at all.** Eighty rows fading up as a window opens reads as
/// the app being slow rather than as anything arriving, and it is not work turning up in front of
/// the reader, it is the pane being pointed somewhere else. That rule is `RowArrival.adopt` and
/// `TranscriptListView.arrivalSession`, which is a piece of bookkeeping rather than a decision, so
/// it is not restated here.
public enum TranscriptMotion {
    /// Whether a stored row of this kind is new on the frame it lands, and therefore worth fading.
    ///
    /// Prose and thinking are not. Both are streamed live first and stored afterwards, and the
    /// streaming views are lined up column for column with their stored twins precisely so that
    /// nothing moves when one replaces the other. Fading the stored row in would undo exactly
    /// that: the answer the reader is halfway through would go out and come back over a fifth of a
    /// second, which is the jump those columns exist to avoid.
    ///
    /// Nor is a user turn. The sentence is drawn from the queue the instant Return is pressed and
    /// the stored row replaces it in the same place at the same measure, so fading it in would
    /// take the owner's own message away and bring it back, which is the flicker the instant echo
    /// exists to remove.
    ///
    /// Everything else genuinely arrives.
    public static func fadesOnArrival(_ kind: MessageKind) -> Bool {
        switch kind {
        case .assistantText, .thinking, .user: false
        default: true
        }
    }
}
