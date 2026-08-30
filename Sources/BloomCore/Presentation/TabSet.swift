import Foundation

/// Which of a workspace's things earn a tab of their own, and the order the strip draws them in.
///
/// The rule is tmux's: **a thing lives in exactly one pane of exactly one tab.** A conversation
/// opened beside another one in a split is a pane of that tab, so it is not also a tab of its own;
/// close the tab and both go. Without the rule the same transcript is reachable two ways and the
/// strip has to mark two entries at once, because it cannot say which of them the user is in.
///
/// So the strip is derived rather than stored. Nothing has to remember to add or remove an entry
/// when a pane opens or closes, which is what the arrangement this replaces got wrong: the strip
/// was a switcher for one pane, so clicking a tab rewrote whatever the pane the user was standing
/// in happened to hold.
public enum TabSet {
    /// Which of a workspace's chats earn a tab at all, which is every chat a person opened and no
    /// crew member.
    ///
    /// **A crew member is drawn in the sidebar, under the workspace it shares a worktree with, and
    /// nowhere else.** It is an ordinary `Session` row, so `Store.sessions(workspaceID:)` hands it
    /// back with the rest and the strip would otherwise grow a tab per agent an orchestrator
    /// started. That is the wrong place for it twice over: the strip is what the person at the
    /// keyboard arranged, and a fan-out of three would push their own conversations off the end of
    /// it. The nesting under a workspace row is what says an agent belongs to that worktree; a tab
    /// says nothing about who started what. See `Crew` and `SidebarSelection.crew`.
    ///
    /// Taken here rather than left to each caller, because "a chat with a parent is not a tab" is
    /// the same rule as "conversations first and tools after them" and both belong in one file.
    public static func tabbable(_ sessions: [Session]) -> [SessionID] {
        sessions.filter { $0.parentSessionID == nil }.map(\.id)
    }

    /// The strip, left to right.
    ///
    /// Two runs, conversations and then tools. Worth keeping exactly as it was: the conversations
    /// are what the app is for, and the shells and pages a workspace collects sit after them
    /// rather than shuffling through them. Each run keeps the order it was handed, so a dragged
    /// tool tab and an archived session both read straight through, and filtering never reorders.
    ///
    /// `claimed` is every content living as a pane of some **other** tab. Other is load bearing:
    /// one chat can sit in two panes of one tab, because a transcript renders twice happily, and a
    /// tab that claimed itself would drop out of the strip it roots. See
    /// `StoredPaneArrangement.claimedContents(root:)`, which is where a caller gets this from.
    public static func entries(
        sessions: [SessionID],
        tools: [String],
        claimed: Set<PaneContent> = []
    ) -> [PaneContent] {
        all(sessions: sessions, tools: tools).filter { !claimed.contains($0) }
    }

    /// Everything a workspace has that COULD be a tab, in the same two runs, including whatever a
    /// tab has absorbed into a pane.
    ///
    /// What a stored strip order is checked against and seeded from. An absorbed thing has to keep
    /// its place in that list even while it is not in the strip, or closing the tab that holds it
    /// would hand it back at the far end instead of where the user left it.
    public static func all(sessions: [SessionID], tools: [String]) -> [PaneContent] {
        sessions.map(PaneContent.chat) + tools.map(PaneContent.tool)
    }
}
