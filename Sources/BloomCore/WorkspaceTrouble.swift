import Foundation

/// Why something Bloom did in a recorded directory failed, said to the owner rather than to an
/// agent.
///
/// The companion of `WorkspaceStartTrouble`, which says the same diagnoses to a model calling
/// `workspace_start`. Two enums rather than one because the two readers can do different things
/// about it: an agent is told to stop guessing and carry on with its own work, and the owner is
/// told which folder to put back. What they share is the method and the probes, which are
/// `CheckoutStanding`: neither of them reads git's stderr to decide what happened.
///
/// This exists because both surfaces used to show `error.readableMessage`, and for a `ShellError`
/// that is the command line, its exit status and its stderr. Creating a workspace in a project
/// whose folder had stopped being a checkout put up "`git for-each-ref --format=%(refname:short)
/// refs/heads` exited 128: fatal: not a git repository (or any of the parent directories): .git",
/// and the diff pane said the same thing about `git rev-parse --verify main^{commit}` for a
/// workspace whose worktree had been deleted underneath it. Neither says which project or which
/// workspace, neither says what to do, and both hand the reader a command they never ran.
///
/// Every sentence names the thing that is wrong, says what is true about it, and ends with the one
/// action that helps. None of them quotes a command. A project's path is named, because that is the
/// owner's own folder and the whole remedy is about it; a worktree's path is not, because it is a
/// directory inside Bloom's workspaces root that the owner did not choose and cannot usefully act
/// on. The workspace's name is named instead.
public enum WorkspaceTrouble: Sendable, Equatable {
    /// The project's folder is not there at all.
    case projectGone(project: String, path: String)
    /// The project's folder is there, and git does not know it any more.
    case projectNotACheckout(project: String, path: String)
    /// The project is a repository that has never been committed to.
    case projectHasNoCommits(project: String)
    /// The branch the worktree would have been cut from is not in the project.
    case baseBranchGone(branch: String, project: String)
    /// The workspace's worktree folder is not there at all.
    case worktreeGone(workspace: String)
    /// The workspace's worktree folder is there, and git does not know it any more.
    case worktreeNotACheckout(workspace: String)
    /// The branch this workspace is measured against is not in the project any more.
    case worktreeBaseBranchGone(branch: String, workspace: String)
    /// Anything else, in git's own words with the command line dropped.
    case unexplained(String)

    /// What the owner is told, whole and on its own.
    public var sentence: String {
        switch self {
        case let .projectGone(project, path):
            return """
                The project '\(project)' is no longer at \(path). It has been moved, renamed or \
                deleted since Bloom recorded it, so there is no repository left to cut a worktree \
                from. Put the folder back, or remove the project from the sidebar and add it again \
                where it lives now.
                """

        case let .projectNotACheckout(project, path):
            return """
                The folder for the project '\(project)' is still at \(path), but it is not a git \
                repository any more. Every worktree is cut from the project's own repository, so \
                nothing can be created here until git knows that folder again. Restore it, or \
                remove the project from the sidebar and add it again wherever the repository is now.
                """

        case let .projectHasNoCommits(project):
            return """
                The project '\(project)' has no commits yet. A worktree is cut from a commit, so \
                there is nothing to start from until the first one is made. Make a commit in the \
                project and try again.
                """

        case let .baseBranchGone(branch, project):
            return """
                The project '\(project)' has no branch called '\(branch)' any more, so there is \
                nothing to cut this worktree from. Choose another base branch, or put that one back.
                """

        case let .worktreeGone(workspace):
            return """
                The worktree for '\(workspace)' is not on disk any more. Something outside Bloom \
                deleted the folder this workspace was working in, so there are no changes left to \
                read. Its branch is still in the project, so archive this workspace and start a \
                new one from that branch to carry on.
                """

        case let .worktreeNotACheckout(workspace):
            return """
                The folder for '\(workspace)' is still there, but git does not know it as a \
                worktree any more, which is what a folder that was deleted and then recreated \
                looks like. Its branch is still in the project, so archive this workspace and \
                start a new one from that branch to carry on.
                """

        case let .worktreeBaseBranchGone(branch, workspace):
            return """
                '\(branch)', the branch '\(workspace)' is measured against, is not in the project \
                any more, so there is nothing to compare this worktree with. Put that branch back, \
                or give the workspace a base branch that is still there.
                """

        case let .unexplained(message):
            return message
        }
    }

    /// Why creating a workspace in this project failed.
    ///
    /// The project, and never the workspace being created, because the worktree is cut from the
    /// project's repository and the branches are listed there. A workspace whose own folder has
    /// been deleted has nothing to do with it, which is why creating one still works while another
    /// one's worktree is missing.
    public static func creating(
        _ error: any Error, project: String, projectPath: String, baseBranch: String
    ) async -> WorkspaceTrouble {
        switch await CheckoutStanding.of(projectPath, branch: baseBranch) {
        case .missing: return .projectGone(project: project, path: projectPath)
        case .notACheckout: return .projectNotACheckout(project: project, path: projectPath)
        case .noCommitsYet: return .projectHasNoCommits(project: project)
        case .branchMissing(let branch): return .baseBranchGone(branch: branch, project: project)
        case .fine: return .unexplained(CheckoutStanding.complaint(about: error))
        }
    }

    /// Why reading a workspace's changes failed.
    ///
    /// Asked of the worktree rather than of the project, because that is where the diff is
    /// measured and because a worktree can be gone while the project it was cut from is perfectly
    /// healthy. A worktree shares its refs with that project, so the branch question is the same
    /// question either way.
    public static func readingChanges(
        _ error: any Error, workspace: String, path: String, baseBranch: String
    ) async -> WorkspaceTrouble {
        switch await CheckoutStanding.of(path, branch: baseBranch) {
        case .missing: return .worktreeGone(workspace: workspace)
        case .notACheckout: return .worktreeNotACheckout(workspace: workspace)
        // A worktree cannot outlive its repository's first commit, so this is the repository the
        // worktree points at having been emptied. The folder is what the reader can act on.
        case .noCommitsYet: return .worktreeNotACheckout(workspace: workspace)
        case .branchMissing(let branch):
            return .worktreeBaseBranchGone(branch: branch, workspace: workspace)
        case .fine: return .unexplained(CheckoutStanding.complaint(about: error))
        }
    }
}
