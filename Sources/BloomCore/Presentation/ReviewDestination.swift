import Foundation

/// Which conversation a review's comments are sent to.
///
/// **Asked for: a review is not always about the chat that happens to be in front.** The comments
/// are the workspace's, not a chat's, so a reviewer reading a diff may well want them to go to the
/// chat that wrote the code, to a second chat kept for cleanup, or to one that has been sitting
/// idle while another ran. Until now the review pane sent to `WorkspaceModel.activeSession` and
/// there was nothing to say otherwise, so the only way to redirect a review was to go and make
/// another chat active first, which moves the whole window.
///
/// The choice is held for the pass being made rather than written to the store, and that is
/// deliberate: it is a fact about the reading somebody is doing now, and a destination remembered
/// across a relaunch would silently send a later review somewhere the reader has forgotten
/// choosing. It falls back the moment it stops being true, which is what `resolved` is for: a
/// chat can be closed or archived from under a review pane that is pointing at it, and a
/// destination that no longer exists must not leave the composer with nowhere to send.
public enum ReviewDestination {
    /// The session a turn sent from the review joins.
    ///
    /// - Parameters:
    ///   - chosen: what the reader picked, or nil for "wherever the workspace is pointed".
    ///   - active: the workspace's active session, which is what the rest of the window follows.
    ///   - sessions: the chats this workspace has, in the order the strip shows them.
    ///
    /// Nil only when the workspace has no chat at all, and then there is nothing to send to and
    /// no composer is drawn. See `ReviewComposer`.
    public static func resolved(
        chosen: SessionID?,
        active: SessionID?,
        sessions: [SessionID]
    ) -> SessionID? {
        if let chosen, sessions.contains(chosen) { return chosen }
        if let active, sessions.contains(active) { return active }
        return sessions.first
    }

    /// Whether the reader is offered a choice at all.
    ///
    /// One chat is not a choice, and a menu that opens onto a single item, already ticked, is a
    /// control that teaches the reader it does nothing. The strip says where the message goes
    /// either way; this only decides whether that sentence is pressable.
    public static func isChoosable(sessions: [SessionID]) -> Bool {
        sessions.count > 1
    }

    /// What the strip above the composer says.
    ///
    /// The title is the chat's own, so a workspace with "Implement the parser" and "Fix the
    /// tests" open reads as one or the other rather than as "Chat" twice. A chat with no title
    /// yet, which is every chat until its first turn is named, falls back to the word this strip
    /// used to say for all of them, and not to `PaneNaming.untitledChat`: "Untitled" is a name
    /// for a tab, and "Messages are sent to Untitled" is a sentence about nothing.
    public static func label(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Messages are sent to \(trimmed.isEmpty ? "Chat" : trimmed)"
    }
}
