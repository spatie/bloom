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
/// still costs, is on that scope's own rows. See `HomeScope.showsFootprints`.
public enum SidebarSelection: Hashable, Sendable {
    case home
    /// The conversation that sits above every project. See `AskConversation`.
    ///
    /// The second root under Home, and adding one back needs an argument, because Search and
    /// Archive were both taken out of the sidebar for being the same list of workspaces Home
    /// already draws. This is not that list under a filter. It is a conversation, it holds state a
    /// chip on Home cannot hold, and it is the only thing in the window scoped to no workspace.
    ///
    /// Its `workspaceID` is nil, and everything that hangs off that gets the right answer for
    /// free: no inspector, no terminal, no diff poll, no pull request accessory, and a Workspace
    /// menu that greys itself. That is the same fall-out `.home` gets, which is what it should be,
    /// because neither of them is a worktree.
    case ask
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
    /// One crew member of a workspace, open for reading and for talking to.
    ///
    /// **Not the case above, and the two must never be merged.** A `.subagent` is a child of one
    /// turn, drawn from the live stream, gone by the next launch. A crew member is a `Session` row
    /// whose `parentSessionID` names the chat that started it: it lives in the same worktree, it
    /// outlives the turn that asked for it, it can be talked to, and it is still there tomorrow.
    /// `Crew`'s head argues that difference in full and says why the word here is not "subagent".
    ///
    /// **It carries its workspace, and `workspaceID` returns it**, for exactly the reason
    /// `.subagent` does: a crew member shares the worktree it was started in, so the terminal, the
    /// diff, the inspector, the toolbar and the Workspace menu are all still about the parent
    /// while you read one. What narrows is the centre column, which shows that agent's own
    /// conversation instead of the workspace's tabs.
    ///
    /// `rememberSelection` therefore stores the parent, which is what should reopen. That is a
    /// weaker claim here than it is for `.subagent`, whose row cannot survive a relaunch at all,
    /// and it is still the right one: a window that reopened inside a crew member's chat would
    /// start you somewhere no person put you.
    case crew(WorkspaceID, SessionID)

    /// The workspace the window is about, which is the line the three cases above keep pointing at.
    ///
    /// **Written out on both sides, because the nil half is a decision rather than a leftover.**
    /// It answered nil through a `default`, so a case added to this enum that carries a workspace
    /// would have got the wrong answer with nothing to compile against, and the wrong answer is
    /// exactly the one `.subagent` and `.crew` document at length: an empty inspector, a greyed
    /// Workspace menu and a stopped composer, on a selection where nothing about the workspace
    /// changed. `.archived` being nil is the other half of the same decision, argued on its own
    /// case, and it now says so here too instead of falling through with `.home` and `.ask`.
    public var workspaceID: WorkspaceID? {
        switch self {
        case .workspace(let id), .subagent(let id, _), .crew(let id, _): id
        case .home, .ask, .archived: nil
        }
    }

    /// The crew member being read, when one is. Only the centre column asks.
    public var crewSessionID: SessionID? {
        if case .crew(_, let id) = self { return id }
        return nil
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
