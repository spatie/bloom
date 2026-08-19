import Foundation

/// Why a restore was refused, in the words a user would need to hear.
public enum WorkspaceRestoreRefusal: Error, CustomStringConvertible, Sendable {
    /// The branch is gone from this Mac and from every remote, so the commits it held are no
    /// longer reachable by name and there is nothing to rebuild a worktree from.
    case branchGone(branch: String)

    public var description: String {
        switch self {
        case .branchGone(let branch):
            "the branch \(branch) no longer exists here or on \(Git.remote)"
        }
    }
}

/// Where the commits an archived workspace was working on can still be found.
///
/// Archiving removes the worktree. Whether the workspace can be worked in again is therefore not a
/// question about the workspace at all, it is a question about the branch, and the branch has
/// three possible fates. Naming them is what stops "Restore" from being a button that works for
/// some rows and fails for others with a git error.
public enum RestoreSource: Sendable, Equatable {
    /// The branch is still on this Mac. Checking it out again at the old path rebuilds the same
    /// tree, commit for commit.
    case localBranch
    /// The branch is gone from here and a remote still carries it. The worktree is cut again from
    /// the remote-tracking ref, which recreates the local branch at the same commits.
    case remoteBranch(ref: String)
    /// Nothing carries the branch any more. A merged pull request whose branch was deleted on both
    /// sides ends here, and so does an archive that deleted the branch. The commits may still be
    /// in the base branch's history, but there is no ref to check out and no worktree to rebuild.
    case gone

    /// Whether a worktree can be built from this at all. The one question the UI asks.
    public var canRebuild: Bool { self != .gone }

    /// Pure, and the whole decision. Kept apart from the git calls that answer the two questions
    /// so the three-way choice can be read and tested on its own.
    public static func of(hasLocalBranch: Bool, remoteRef: String?) -> RestoreSource {
        if hasLocalBranch { return .localBranch }
        if let remoteRef, !remoteRef.isEmpty { return .remoteBranch(ref: remoteRef) }
        return .gone
    }

    /// What to put in front of a person looking at an archived workspace.
    ///
    /// The last sentence of the `gone` case is the point of this whole type: reading the
    /// transcript and working in the workspace again are two different things, and only one of
    /// them has stopped being possible.
    public func explanation(branch: String, remote: String = Git.remote) -> String {
        switch self {
        case .localBranch:
            """
            The branch \(branch) is still here, so the worktree can be built from it again with \
            every commit in place.
            """
        case .remoteBranch:
            """
            The branch \(branch) is gone from this Mac, but \(remote) still has it, so the \
            worktree can be cut again from there.
            """
        case .gone:
            """
            The branch \(branch) no longer exists here or on \(remote), so there is nothing left \
            to build a worktree from and this workspace cannot be worked in again. Everything it \
            said is still here to read.
            """
        }
    }
}

/// Where a worktree goes when the place it wants is taken.
///
/// The rule is `createWorkspace`'s, lifted out of it so that creating a worktree and rebuilding
/// one cannot drift apart: a numeric suffix, counting from 2, until a free name is found. Nothing
/// is ever written over. A directory sitting at an archived workspace's old path belongs to
/// somebody, even if only to a `git worktree remove` that failed half way, and a restore that
/// deleted it would be the archive's mistake made twice.
public enum WorktreePath {
    /// Pure. `isOccupied` is a closure rather than a set so the caller can ask the disk, which is
    /// the only authority on this, without this rule having to know that it did.
    public static func free(preferred: String, isOccupied: (String) -> Bool) -> String {
        var candidate = preferred
        var suffix = 2
        while isOccupied(candidate) {
            candidate = "\(preferred)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}

/// What a restore actually did, which is not always what was asked for.
public struct RestoreOutcome: Sendable, Equatable {
    public var workspace: Workspace
    public var source: RestoreSource
    /// The path the workspace was archived from, when the worktree had to be rebuilt beside it
    /// because that one was taken. Nil when it went back exactly where it was.
    public var relocatedFrom: String?

    public init(workspace: Workspace, source: RestoreSource, relocatedFrom: String? = nil) {
        self.workspace = workspace
        self.source = source
        self.relocatedFrom = relocatedFrom
    }
}

/// Whether an archive left the workspace rebuildable, which is a narrower question than
/// `WorkspaceSafetyReport.isSafeToDiscard` asks and a different one.
///
/// `isSafeToDiscard` weighs the commits, because deleting the branch as well would make them
/// unreachable. Removing only the worktree does not touch them: the branch is what holds them, and
/// a branch that still exists can be checked out again with every commit in place. So commits are
/// not counted here.
///
/// What is counted is everything git was not keeping a copy of, because that lives in the worktree
/// directory and nowhere else. Once `git worktree remove` has deleted the directory there is no
/// second copy to check out.
public extension WorkspaceSafetyReport {
    var isRestorableFromBranch: Bool {
        !hasUncommittedChanges
            && untrackedFiles.isEmpty
            && modifiedIgnoredFiles.isEmpty
            && detachedCommits == 0
    }
}

/// Putting an archived workspace back.
///
/// Restoring rebuilds the worktree from whatever still holds the branch. It never claims to bring
/// back what git was not keeping a copy of: uncommitted edits, untracked files, modified ignored
/// files and commits on a detached HEAD all died with the directory, which is exactly what
/// `WorkspaceSafetyReport` lists before the archive happens.
///
/// It is offered for every archived workspace anyway, and not only for the archive that report
/// cleared. An archive nobody could have taken back is precisely the one somebody wants back a
/// week later, and a Restore that appears only on the rows that lost nothing is a Restore that is
/// never there when it is needed. What the archive cost is said at the time; what a restore can
/// still do is said here.
///
/// Deliberately not called "unarchive": it restores what git can restore and says so, rather than
/// implying the workspace comes back exactly as it was.
public extension WorkspaceManager {
    /// Whether the worktree could be rebuilt right now, asked before an undo is offered.
    ///
    /// Local and cheap on purpose: this runs on the way out of every archive, and a network fetch
    /// there would put the whole undo registration behind a twenty second timeout. The deliberate
    /// restore asks the fuller question through `restoreSource`.
    func canRestore(workspace: Workspace, repo: Repo) async -> Bool {
        guard !FileManager.default.fileExists(atPath: workspace.path) else { return false }
        return await Git.branchExists(workspace.branch, in: repo.path)
    }

    /// Where this workspace's branch still lives, if anywhere.
    ///
    /// The remote is asked over the network rather than from the remote-tracking refs alone,
    /// because a ref that was never fetched is not evidence of absence, and the case this exists
    /// for is a branch that was deleted locally and is still on the server. A fetch that fails
    /// (offline, or credentials nobody has given) leaves whatever was last fetched in place, which
    /// is the honest fallback rather than an error.
    func restoreSource(workspace: Workspace, repo: Repo) async -> RestoreSource {
        if await Git.branchExists(workspace.branch, in: repo.path) { return .localBranch }

        _ = await Git.fetch(workspace.branch, in: repo.path)
        let ref = "refs/remotes/\(Git.remote)/\(workspace.branch)"
        let remoteRef = await Git.revision(of: ref, in: repo.path) == nil ? nil : ref
        return RestoreSource.of(hasLocalBranch: false, remoteRef: remoteRef)
    }

    /// Recreates the worktree and marks the workspace active again.
    ///
    /// The copied files come back too. `createWorkspace` copies `files_to_copy` (`.env*` by
    /// default) into every new worktree, and those are ignored files that git will not restore,
    /// so a restore without this step would hand back a worktree missing the environment the
    /// workspace was set up with.
    @discardableResult
    func restore(workspace: Workspace, repo: Repo) async throws -> RestoreOutcome {
        try await restore(
            workspace: workspace,
            repo: repo,
            from: await restoreSource(workspace: workspace, repo: repo)
        )
    }

    /// The same, for a caller that has already worked out where the branch is and does not want
    /// the network asked twice.
    @discardableResult
    func restore(
        workspace: Workspace, repo: Repo, from source: RestoreSource
    ) async throws -> RestoreOutcome {
        guard source.canRebuild else {
            throw WorkspaceRestoreRefusal.branchGone(branch: workspace.branch)
        }

        let path = WorktreePath.free(preferred: workspace.path) {
            FileManager.default.fileExists(atPath: $0)
        }

        // The base is only consulted when the branch has to be created. For a surviving local
        // branch that never happens and this checks the branch out; for a branch that only the
        // remote still has, the remote-tracking ref IS the base, and cutting from it recreates the
        // local branch at the commits the server has.
        let base: String
        if case .remoteBranch(let ref) = source {
            base = ref
        } else {
            base = workspace.baseBranch
        }

        try await Git.addWorktree(
            repo: repo.path, path: path, branch: workspace.branch, base: base
        )

        let settings = SettingsLoader.load(repo: repo.path)
        try copyFiles(settings.filesToCopy, from: repo.path, to: path)

        // Three columns, not eighteen. `git worktree add` and the file copy above take long
        // enough for a turn to finish or a diff stat pass to land, and a restore that put the
        // whole value back would undo whatever they wrote.
        let updated = try await store.update(workspaceID: workspace.id) {
            $0.state = .active
            $0.archivedAt = nil
            $0.path = path
        }
        guard let restored = updated else { throw WorkspaceError.workspaceGone(workspace.name) }
        return RestoreOutcome(
            workspace: restored,
            source: source,
            relocatedFrom: path == workspace.path ? nil : workspace.path
        )
    }
}
