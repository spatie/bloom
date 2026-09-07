import Foundation

extension WorkspaceManager {
    /// An agent can rename a branch without changing Bloom's workspace row. Read
    /// HEAD alongside the existing file refresh, not on a second polling loop. The root comes
    /// back in the same git call so an empty directory left by a removed worktree cannot make
    /// git walk up and tell us the parent repository's branch instead.
    public func refreshBranch(workspace: Workspace) async {
        guard workspace.state == .active, !Task.isCancelled,
              let result = try? await Git.run(
                  ["rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"], in: workspace.path
              ), result.ok else { return }
        let lines = result.lines
        guard lines.count == 2,
              URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: workspace.path).resolvingSymlinksInPath().path,
              lines[1] != "HEAD", Git.isValidBranchName(lines[1]),
              lines[1] != workspace.branch, lines[1] != workspace.baseBranch,
              let repo = try? await store.repo(id: workspace.repoID),
              lines[1] != repo.defaultBranch,
              !Task.isCancelled else { return }

        // A checkout is not a rename. The recorded branch is also what archive may delete, so
        // following a temporary checkout of main would silently transfer ownership to main.
        // Only a genuinely missing old local ref permits adoption; an error is not absence.
        guard Git.isValidBranchName(workspace.branch),
              let old = try? await Git.run(
                  ["show-ref", "--verify", "--quiet", "--", "refs/heads/\(workspace.branch)"],
                  in: workspace.path
              ), old.status == 1, !Task.isCancelled else { return }
        try? await store.updateCheckedOutBranch(lines[1], observed: workspace)
    }
}
