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
    /// else, and the create sheet has a tab for exactly that. So the sentence says so, and nothing
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
}

public extension BranchHolder {
    /// Which branches of this repository are taken, and by what.
    ///
    /// Pure over what git printed and what the database holds, so the awkward cases can be held by
    /// the suite rather than by having the right folders on the machine. Three of them matter.
    ///
    /// A bare repository's record and a detached head hold no branch, so neither takes one.
    ///
    /// The main checkout is in the listing like every other worktree and is emphatically not
    /// another tool holding the branch, so it gets its own case: telling somebody that Conductor
    /// has his project's own `main` would send him looking for a window that does not exist.
    ///
    /// A workspace name wins over the path of the same worktree. Bloom's own worktrees are in the
    /// listing too, and the answer for one of those is the workspace, which is a thing the app can
    /// select. `workspaceNames` is read second for exactly that reason.
    static func byBranch(
        worktrees: [WorktreeEntry],
        projectPath: String,
        workspaceNames: [String: String] = [:]
    ) -> [String: BranchHolder] {
        let project = standardised(projectPath)
        var holders: [String: BranchHolder] = [:]
        for entry in worktrees {
            guard !entry.isBare, let branch = entry.branch, !branch.isEmpty else { continue }
            // First writer wins. Two worktrees cannot hold one branch, so a duplicate here is a
            // listing racing a `git worktree prune`, and the earlier record is the main checkout
            // or the older worktree either way.
            guard holders[branch] == nil else { continue }
            holders[branch] = standardised(entry.path) == project
                ? .projectCheckout(path: entry.path)
                : .otherWorktree(path: entry.path)
        }
        for (branch, name) in workspaceNames where !branch.isEmpty {
            holders[branch] = .workspace(name)
        }
        return holders
    }

    /// The live workspaces of one project, by the branch each one is on.
    ///
    /// Archived rows are left out because their worktrees are gone, and the project filter is not
    /// tidiness: a branch name is not unique across repositories, and `main` or `develop` exists
    /// in nearly all of them, so an unfiltered list once labelled this project's branch as held by
    /// a workspace in another one, and selecting that row left the sheet in an unrelated project.
    static func names(of workspaces: [Workspace], in repoID: RepoID) -> [String: String] {
        Dictionary(
            workspaces
                .filter { $0.state == .active && $0.repoID == repoID }
                .map { ($0.branch, $0.name) },
            // Two live workspaces in one project cannot hold the same branch, so a duplicate is a
            // row that has not caught up with a worktree that has gone. The first is as good an
            // answer as there is, and it is the one `WorkspaceCheckoutPlan.workspaceHolding`
            // finds when the row is selected.
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Enough of a path to compare two of them by.
    ///
    /// Textual on purpose: resolving symlinks would touch the disk and put a filesystem call
    /// inside a function whose whole value is that it is pure. Git prints absolute paths and Bloom
    /// records absolute paths, so what is left to reconcile is a trailing slash and a `..`.
    private static func standardised(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}

/// Thrown before `git worktree add` rather than caught after it.
///
/// The whole reason this is a type and not a string: `WorkspaceTrouble.creating` reads the branch
/// and the holder off it and writes the owner's sentence itself, so nothing anywhere has to parse
/// git's stderr to find out what happened, and "exit status 128" cannot reach a dialogue by
/// accident. `description` is the fallback for a caller that has no diagnosis of its own; see
/// `Error.readableMessage`, which reaches it.
public struct BranchInUse: Error, Sendable, Equatable, CustomStringConvertible {
    public let branch: String
    public let holder: BranchHolder

    public init(branch: String, holder: BranchHolder) {
        self.branch = branch
        self.holder = holder
    }

    public var description: String { holder.refusal(branch: branch) }
}
