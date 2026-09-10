import Foundation
import BloomClient

public typealias BranchHolder = BloomClient.BranchHolder

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
