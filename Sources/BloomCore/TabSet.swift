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
