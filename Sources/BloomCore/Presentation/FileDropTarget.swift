import CoreGraphics

/// Which chat a file dropped on part of the window with no drop target of its own is attached to.
///
/// The focused chat, except over the side conversation's card, where it is the card's chat: the
/// card hangs over the transcript and a file let go on it is meant for the question being asked
/// there. Only over it. Beside it the owner is pointing at the main conversation, and a card that
/// claimed the whole window would take every drop for as long as it stayed open.
///
/// `point` is where the drag is, in the same space as `cardFrame`. Nil means there is no pointer to
/// ask, which is a drop over the sidebar: no card is ever drawn there.
public enum FileDropTarget {
    /// Retained workspace views stay in the window behind Home and standalone conversations.
    /// A drop must follow the visible selection, never the last workspace's retained composer.
    public static func focusedSession(selection: SidebarSelection, workspaceChat: SessionID?) -> SessionID? {
        switch selection {
        case .conversation(let id), .crew(_, let id): id
        case .workspace: workspaceChat
        case .home, .mail, .archived, .archivedConversation, .subagent, .subagentCall: nil
        }
    }

    public static func resolve(
        focused: SessionID?, sideConversation: SessionID?, cardFrame: CGRect, at point: CGPoint?
    ) -> SessionID? {
        guard let focused else { return nil }
        guard let sideConversation, let point, cardFrame.contains(point) else { return focused }
        return sideConversation
    }
}
