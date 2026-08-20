import Foundation

/// What the dock icon says while Bloom is behind something else.
///
/// A type of its own, in the core, because the number is a judgement rather than a passthrough:
/// it decides what "finished" means, what "read" means, and which of the two counts a person
/// would say out loud. Keeping the decision here means it can be tested against fixtures rather
/// than read off a dock icon.
public enum DockBadge {
    /// The user default that switches the badge on. On unless it has been turned off.
    public static let settingKey = "dock.badgesUnread"

    /// How many workspaces have finished work nobody has read yet.
    ///
    /// **Workspaces, not sessions.** A workspace can hold several sessions, and `unread` is a flag
    /// on the workspace: it is raised when a turn finishes in a workspace the user is not looking
    /// at, and lowered when they look at it. The sidebar lists workspaces, the sidebar's unread
    /// mark is per workspace, and "three agents are waiting on me" means three rows, so counting
    /// sessions would give a number that matches nothing on screen.
    ///
    /// **Running workspaces are left out.** `WorkspaceStatus` resolves `.running` ahead of
    /// `.unread`, so a workspace whose agent has started another turn shows a running mark rather
    /// than an unread one. Counting it would make the badge disagree with the sidebar it is
    /// summarising. It comes back the moment that turn ends and nobody has read it.
    ///
    /// Note that "finished" includes turns that failed or were cancelled. That is deliberate:
    /// what the flag means is that an agent stopped and left something the user has not seen, and
    /// a turn that died is exactly that.
    public static func unreadCount(
        in workspaces: [Workspace],
        isRunning: (Workspace) -> Bool
    ) -> Int {
        workspaces.count { $0.unread && !isRunning($0) }
    }

    /// How many workspaces have an agent blocked on a question nobody has answered.
    ///
    /// Workspaces rather than questions, for the same reason `unreadCount` counts workspaces: the
    /// sidebar lists workspaces and the badge summarises the sidebar. One agent that asked three
    /// things in a row is one row to go and look at.
    public static func waitingCount(
        in workspaces: [Workspace],
        isAwaitingPermission: (Workspace) -> Bool
    ) -> Int {
        workspaces.count(where: isAwaitingPermission)
    }

    /// The badge text, or nil for no badge at all.
    ///
    /// Nil rather than "0". An empty badge is a red dot on the dock icon announcing that nothing
    /// happened, which is worse than no badge.
    ///
    /// Waiting wins over unread while anything is waiting, and it is not added to it. The badge is
    /// one number and it has to mean one thing: an unread result will still be there in an hour,
    /// while a blocked agent is burning the hour. Summing the two would produce a number that
    /// describes neither and matches nothing in the sidebar.
    public static func label(unread: Int, waiting: Int = 0, isEnabled: Bool) -> String? {
        guard isEnabled else { return nil }
        if waiting > 0 { return String(waiting) }
        guard unread > 0 else { return nil }
        return String(unread)
    }
}
