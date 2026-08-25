import Foundation

/// Why `workspace_start` could not cut a worktree, in terms an agent can act on.
///
/// The tool used to answer every failure with `error.readableMessage`, and for a `ShellError` that
/// is the git command line, its exit status and its stderr: "`git worktree add -b do-thing --
/// /Users/…/workspaces/bloom-git-711961F7…/do-thing main` exited 128: fatal: invalid reference:
/// main". Three things are wrong with that. It quotes an internal worktree path the caller has no
/// business seeing and cannot use. It hands the model a command line, which invites it to reason
/// about git rather than about the tool it called. Worst of all, git says the same eight words for
/// two completely different situations, and one of them is a trap: in a repository with no commits
/// every branch name is an invalid reference, so a model told only "invalid reference: main" reads
/// it as a typo and retries with master, then develop, then trunk, burning a call each time on a
/// repository where no name could ever have worked. The branch it was told about is the default
/// one it never asked for, which makes guessing look all the more reasonable.
///
/// So the failure is diagnosed rather than reported. The distinct causes get distinct sentences,
/// each saying what is true and what to do next, and none of them quotes a command or a path
/// inside Bloom's own worktree root.
public enum WorkspaceStartTrouble: Sendable, Equatable {
    /// The project is not where Bloom recorded it. Nothing the agent does will fix this.
    case projectMissingFromDisk(project: String, path: String)
    /// The repository exists and has never been committed to, so there is no commit to cut from.
    case noCommitsYet(project: String)
    /// The branch to cut from is not there. `wasRequested` false means the agent left
    /// `base_branch` out and this is the project's default, which changes what it should do next.
    case baseBranchMissing(branch: String, project: String, wasRequested: Bool, branches: [String])
    /// Anything else, said in git's own words with the command line and the internal path dropped.
    case unexplained(String)

    /// What the agent is told, whole and on its own.
    public var sentence: String {
        switch self {
        case let .projectMissingFromDisk(project, path):
            return """
                Bloom could not start that workspace because the project '\(project)' is no longer \
                on disk at \(path). It has been moved, renamed or deleted since Bloom recorded it, \
                so there is no repository left to cut a worktree from. Retrying will not help. \
                Tell the owner where the project went.
                """

        case let .noCommitsYet(project):
            return """
                Bloom could not start that workspace because the project '\(project)' has no \
                commits yet. A worktree is cut from a commit, so there is nothing to start from \
                until the first one is made. No branch name will work, so do not retry with \
                another one. Say so and carry on with your own work.
                """

        case let .baseBranchMissing(branch, project, wasRequested, branches):
            let opening = wasRequested
                ? "Bloom could not start that workspace because the project '\(project)' has no "
                    + "branch called '\(branch)'."
                : "Bloom could not start that workspace because '\(branch)', the default branch "
                    + "Bloom cuts from when a call does not name one, does not exist in the "
                    + "project '\(project)'."
            guard !branches.isEmpty else {
                return opening + " It has no branches at all, so there is nothing to cut from. "
                    + "Do not retry with another name. Say so and carry on with your own work."
            }
            // Below the guard, not above it. It used to be the first line of this case, three
            // lines before the emptiness check written to protect it, and `listing` reached
            // `shown[-1]` on an empty list and killed the app. Reached whenever a project has
            // commits but no local branches, and whenever `Git.branches` throws and a `try?` turns
            // that into an empty array, which is the same call that produced this failure.
            let whichBranches = Self.listing(branches)
            let hasOne = branches.count == 1
            return opening
                + (hasOne ? " Its only branch is \(whichBranches)." : " Its branches are \(whichBranches).")
                + (hasOne
                    ? " Call workspace_start again with that as base_branch."
                    : " Call workspace_start again with one of those as base_branch.")

        case let .unexplained(message):
            return "Bloom could not start that workspace: \(message)"
        }
    }

    /// The trouble behind a failed start, worked out by asking the repository rather than by
    /// reading git's stderr.
    ///
    /// Parsing the stderr was the obvious route and it does not work: the two cases that matter
    /// most produce the same string, and the third never reaches git at all, because launching a
    /// subprocess in a directory that has been deleted throws a Cocoa error before git runs and
    /// that error names only the missing directory's last path component. The questions live in
    /// `CheckoutStanding` because the diff pane and the create sheet have to ask exactly the same
    /// ones, and they only run once a start has already failed, so the cost is paid on the unhappy
    /// path alone.
    public static func diagnose(
        _ error: any Error,
        project: String,
        projectPath: String,
        baseBranch: String,
        wasRequested: Bool
    ) async -> WorkspaceStartTrouble {
        switch await CheckoutStanding.of(projectPath, branch: baseBranch) {
        // A folder that is still there but is no longer a checkout is the same news to an agent as
        // one that has gone: either way there is no repository left to cut from and nothing it can
        // do about it. The owner is told the two apart, in `WorkspaceTrouble`, because the owner
        // is the one who can put it back.
        case .missing, .notACheckout:
            return .projectMissingFromDisk(project: project, path: projectPath)

        case .noCommitsYet:
            return .noCommitsYet(project: project)

        case .branchMissing(let branch):
            let branches = (try? await Git.branches(of: projectPath)) ?? []
            return .baseBranchMissing(
                branch: branch,
                project: project,
                wasRequested: wasRequested,
                branches: branches
            )

        case .fine:
            return .unexplained(CheckoutStanding.complaint(about: error))
        }
    }

    /// Named branches, capped. A repository with two hundred branches would otherwise spend the
    /// whole tool result listing them, and the caller only needs enough to pick one.
    /// Total over its input, including the empty list.
    ///
    /// The caller guards emptiness and used to do it three lines too late, which trapped. The
    /// guard is in the right place now and this answers for nothing anyway, because a sentence
    /// built from no branches is a sentence with no business being built. Two agreeing mechanisms,
    /// because the one that was supposed to be enough was not.
    private static func listing(_ branches: [String]) -> String {
        let shown = branches.prefix(10).map { "'\($0)'" }
        let rest = branches.count - shown.count
        guard let last = shown.last else { return "" }
        var text = shown.count == 1
            ? last
            : shown.dropLast().joined(separator: ", ") + " and " + last
        if rest > 0 { text += ", and \(rest) more" }
        return text
    }
}
