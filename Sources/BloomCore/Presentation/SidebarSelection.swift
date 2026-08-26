import Foundation

/// What the sidebar is pointing at, and therefore what the whole window is about.
///
/// In the core rather than beside `AppModel`, because a decision taken inside the app target is a
/// decision nothing can test. The one that matters is the last: `.workspace(id)` and
/// `.archived(id)` are different values with different hashes, which is what stops an archived
/// workspace being reopened as a live one.
/// It is one case shorter than it looks, and two shorter than it was. `.search` and `.archive`
/// were destinations of their own, and both were the same list of workspaces Home already draws:
/// searching is a state of Home, reached from the window's own search field, and the archive is a
/// scope on it. What the Archive screen held that Home did not, the bytes each finished workspace
/// still costs, is Settings > Storage now. See `HomeScope`.
public enum SidebarSelection: Hashable, Sendable {
    case home
    case workspace(WorkspaceID)
    /// An archived workspace, open for reading.
    ///
    /// Its own case rather than a flag on `workspace`, because an archived workspace is not a
    /// workspace the window can do anything to. Its worktree is gone, so the inspector has no
    /// diff to show, the toolbar has nothing to act on, the composer has nowhere to send a prompt
    /// and every item in the Workspace menu but one points at a directory that is not there.
    /// Keeping it out of `workspaceID` is what makes all of that fall out for free: the inspector
    /// hides itself, the menu items grey, the background refresh skips it and nothing tries to
    /// reopen it on the next launch.
    case archived(WorkspaceID)
    /// One subagent of the turn running in a workspace, open for reading.
    ///
    /// **It carries its workspace, and `workspaceID` returns it.** That one line is the whole
    /// selection decision. A subagent has no worktree, no branch, no terminal and nothing to
    /// commit, so selecting one cannot mean what selecting a workspace means. But the terminal,
    /// the diff, the composer, the toolbar, the Workspace menu and the session restore all hang
    /// off `selection.workspaceID`, and every one of them is still about the parent while you read
    /// a child. So a subagent selection IS a workspace selection, with exactly one thing narrowed:
    /// the centre column, which shows that subagent's own transcript instead of the chat.
    ///
    /// The alternative was a case whose `workspaceID` was nil, and it would have emptied the
    /// inspector, greyed the menu and stopped the composer the moment you clicked a row to see
    /// what a subagent said. Nothing about the workspace changed when you did that.
    ///
    /// `rememberSelection` therefore stores the parent, which is what should reopen: the subagent
    /// is gone by the next launch by construction. See `SubagentRoster`.
    case subagent(WorkspaceID, SubagentID)

    public var workspaceID: WorkspaceID? {
        switch self {
        case .workspace(let id), .subagent(let id, _): id
        default: nil
        }
    }

    /// The subagent being read, when one is. Only the centre column asks.
    public var subagentID: SubagentID? {
        if case .subagent(_, let id) = self { return id }
        return nil
    }

    public var archivedWorkspaceID: WorkspaceID? {
        if case .archived(let id) = self { return id }
        return nil
    }
}
