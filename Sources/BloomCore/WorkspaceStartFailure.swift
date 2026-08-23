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
            let whichBranches = Self.listing(branches)
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
    /// that error names only the missing directory's last path component. Three probes against the
    /// repository answer all three, and they only run once a start has already failed, so the cost
    /// is paid on the unhappy path alone.
    public static func diagnose(
        _ error: any Error,
        project: String,
        projectPath: String,
        baseBranch: String,
        wasRequested: Bool
    ) async -> WorkspaceStartTrouble {
        guard FileManager.default.fileExists(atPath: projectPath),
              await Git.isRepository(projectPath)
        else {
            return .projectMissingFromDisk(project: project, path: projectPath)
        }

        guard await Git.hasCommits(in: projectPath) else {
            return .noCommitsYet(project: project)
        }

        if !(await Git.branchExists(baseBranch, in: projectPath)) {
            let branches = (try? await Git.branches(of: projectPath)) ?? []
            return .baseBranchMissing(
                branch: baseBranch,
                project: project,
                wasRequested: wasRequested,
                branches: branches
            )
        }

        return .unexplained(plainly(error))
    }

    /// git's complaint without the command line Bloom built to provoke it.
    ///
    /// `ShellError.description` exists for a log, where the argv is the most useful thing in it.
    /// In front of a model it is the least useful: it is the one part of the failure the caller
    /// neither chose nor can change.
    private static func plainly(_ error: any Error) -> String {
        guard let shell = error as? ShellError else { return error.readableMessage }
        let stderr = shell.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stderr.isEmpty else { return "git exited \(shell.status) without saying why." }
        return stderr.hasSuffix(".") ? stderr : stderr + "."
    }

    /// Named branches, capped. A repository with two hundred branches would otherwise spend the
    /// whole tool result listing them, and the caller only needs enough to pick one.
    private static func listing(_ branches: [String]) -> String {
        let shown = branches.prefix(10).map { "'\($0)'" }
        let rest = branches.count - shown.count
        var text = shown.count == 1 ? shown[0] : shown.dropLast().joined(separator: ", ") + " and " + shown[shown.count - 1]
        if rest > 0 { text += ", and \(rest) more" }
        return text
    }
}
