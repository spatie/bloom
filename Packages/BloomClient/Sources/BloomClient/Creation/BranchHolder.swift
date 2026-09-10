import Foundation

/// What is already sitting on a branch, when something is.
///
/// **The bug this exists for.** `ExistingBranch.inUseBy` was filled from Bloom's own workspace
/// rows and from nothing else, so a worktree cut by Conductor, by another agent runner, or by
/// hand was invisible to it. The picker drew pull request #362 as a free row, Bloom cut a
/// worktree and ran `gh pr checkout`, and git refused: "fatal: 'freekmurze/figma-mcp-check' is
/// already used by worktree at '/Users/freek/conductor/workspaces/there-there/adelaide'". That
/// sentence reached a dialogue with "failed to run git: exit status 128" still on the end of it,
/// which names a folder Bloom never mentions anywhere else and reads as a crash rather than as a
/// refusal.
///
/// Git has always been the source of truth here and the database never was: `git worktree list`
/// knows every worktree of a repository whoever made it. What the database is still needed for is
/// the **name**. A branch held by one of Bloom's own workspaces is worth saying by workspace name,
/// because the way out is to go there and the app can take you; a branch held by anything else is
/// worth saying by path, because the path is the only thing that says which window to go and
/// close. Printing a bare path where a workspace name would have gone reads as a workspace called
/// `/Users/freek/conductor/...`, so the two cases are two cases.
public enum BranchHolder: Sendable, Hashable, Codable {
    /// One of Bloom's own live workspaces, by name.
    case workspace(String)
    /// The project's own checkout, which appears in `git worktree list` like any other worktree
    /// and is not another tool holding anything. Usually the default branch, which the picker
    /// drops anyway, and not always: a project left on a feature branch holds that branch too.
    case projectCheckout(path: String)
    /// A worktree Bloom did not make: Conductor's, another runner's, or one cut by hand.
    case otherWorktree(path: String)

    /// Whether the app can take somebody to the holder. Only its own workspaces.
    public var isBloomWorkspace: Bool {
        if case .workspace = self { return true }
        return false
    }

    /// The note drawn at the right of a row in the source picker.
    ///
    /// Deliberately short, and deliberately without the path. That label is one line, right
    /// aligned and truncated from the tail, so a path renders as "In use by /Users/freek/conduc…",
    /// which names nothing. The path belongs in `refusal(branch:)`, which is drawn full width
    /// under the composer the moment such a row is picked.
    public var note: String {
        switch self {
        case .workspace(let name): "In use by \(name)"
        case .projectCheckout: "Checked out in the project"
        case .otherWorktree: "Checked out elsewhere"
        }
    }

    /// The holder as a sentence names it.
    public var described: String {
        switch self {
        case .workspace(let name): "the workspace '\(name)'"
        case .projectCheckout(let path): "the project's own checkout at \(path)"
        case .otherWorktree(let path): "the worktree at \(path)"
        }
    }

    /// How this particular holder is persuaded to let the branch go.
    ///
    /// Shared with `WorkspaceTrouble.createBranchInUse`, which says the same thing in paragraphs
    /// under a warning triangle, so the sheet's line and the dialogue cannot come to disagree
    /// about what the owner should do.
    public var wayOut: String {
        switch self {
        case .workspace: "Go to that workspace to carry on there"
        case .projectCheckout: "Switch the project itself to another branch"
        case .otherWorktree: "Close or remove that worktree to free the branch"
        }
    }

    /// Why this branch cannot be opened in a new workspace, and what can be had instead.
    ///
    /// **The offer at the end is the point.** Git allowing one worktree per branch is not
    /// negotiable and `--force` is not the answer: two worktrees on one branch is how work is
    /// lost, which is the thing this app exists to avoid. But the code is still reachable, because
    /// git is perfectly happy to cut a *new* branch from a branch that is checked out somewhere
    /// else, and the create window has a tab for exactly that. So the sentence says so, and nothing
    /// acts on it: opening somebody's branch and starting a branch beside it are different
    /// intentions, and Bloom does not get to pick between them on his behalf.
    public func refusal(branch: String) -> String {
        let opening: String
        switch self {
        case .workspace(let name):
            opening = "'\(branch)' is already open in '\(name)'."
        case .projectCheckout(let path):
            opening = "'\(branch)' is the branch the project itself is on, at \(path)."
        case .otherWorktree(let path):
            opening = "'\(branch)' is checked out at \(path), which is not one of Bloom's workspaces."
        }
        return opening
            + " Git allows one worktree per branch, so it cannot be opened twice. \(wayOut),"
            + " or start a new branch from '\(branch)' on the Create new branch tab,"
            + " which gets you the same code."
    }

    /// The same refusal for a caller with no screen, which is `workspace_start` over the bridge.
    ///
    /// Two audiences and one fact, in the shape `FolderRefusal` already uses for the same split:
    /// the opening and the way out are shared, and only the last clause differs, because a tab
    /// strip is not something an agent can be sent to. What it can do is ask again, so the offer
    /// names the argument instead of the tab. Sending a model to a control it cannot see is how
    /// it ends up describing the app to the owner rather than doing the work.
    public func agentRefusal(branch: String) -> String {
        let opening: String
        switch self {
        case .workspace(let name):
            opening = "'\(branch)' is already open in Bloom's workspace '\(name)'."
        case .projectCheckout(let path):
            opening = "'\(branch)' is the branch the project itself is on, at \(path)."
        case .otherWorktree(let path):
            opening = "'\(branch)' is checked out at \(path), which is not one of Bloom's workspaces."
        }
        return opening
            + " Git allows one worktree per branch, so Bloom cannot open it again."
            + " Ask again with base_branch '\(branch)' instead of existing_branch, which cuts a"
            + " new branch from it and starts you on the same code, or leave it and say so."
    }
}
