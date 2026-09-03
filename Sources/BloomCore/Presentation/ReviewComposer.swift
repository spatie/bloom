import Foundation

/// Whether the review pane draws a composer of its own.
///
/// **The bug.** Split a tab so a conversation sits beside a file and there were two composers on
/// screen at once, a hand's width apart, bound to the same draft: the owner typed into the box
/// under the README and watched the same words appear in the box under the chat, the second of
/// them wearing a strip that read "Messages are sent to Chat". Two boxes for one draft is not a
/// redundancy, it is a reader wondering which of them is the real one.
///
/// **Why the review has a composer at all**, which is the half not to throw away while fixing the
/// other. Review comments are staged as chips on the transcript, and before this composer existed
/// you placed them on the diff and then had to leave the diff to send them. A review alone in its
/// tab has nowhere else to type, so removing the box outright was tried and is worse than the bug.
///
/// So it is drawn unless the conversation it sends to is already on screen in the same tab, and
/// both halves of that sentence carry weight.
///
/// The **tab** is the unit because that is what "on screen" means here. Only one tab's panes are
/// drawn at a time, so a chat in another tab is one the reader can neither see nor type into, and
/// counting it would leave a review pane with no way to send at all.
///
/// It is the **destination** session rather than any conversation because the chips are staged on
/// one transcript. A pane holding some other session is a composer that sends somewhere else:
/// hiding this box for it would strand the comments just written on this diff, which is the very
/// walk to another pane the composer was put here to spare.
public enum ReviewComposer {
    /// - Parameters:
    ///   - destination: the conversation a turn sent from the review joins, which is the
    ///     workspace's active session, and nil when the workspace has no session at all.
    ///   - panes: what every pane of the tab holding this review is showing, the review's own pane
    ///     included. A tab nobody has split is one entry.
    public static func isDrawn(destination: SessionID?, panes: [PaneContent]) -> Bool {
        // Nothing to send to, so nothing to type into. The view reaches the same answer by having
        // no transcript to bind, and saying it here is what lets the case be held still.
        guard let destination else { return false }
        return !panes.contains(.chat(destination))
    }
}
