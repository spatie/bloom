import Foundation

/// Whether the pull request gh found for a branch is the one this workspace is about.
///
/// gh has no other way of looking one up: `gh pr view <branch>` matches on the branch NAME, and it
/// answers with merged and closed pull requests as readily as with open ones. Branch names are
/// reused constantly, by people and by Bloom itself, which derives one from the task and from a
/// sea. So a brand new workspace called `update-composer-json`, with nothing written in it yet and
/// an agent still on its first turn, was handed pull request #371 from the last time that name was
/// used: the strip said **Merged**, in GitHub's violet, and offered Archive over work that had not
/// started. Nothing about that workspace had ever been pushed anywhere.
///
/// Two facts settle it, and both are already on hand:
///
/// - **What the worktree was checked out from.** `gh pr checkout` writes the pull request into the
///   branch's own git config, so a review workspace can say which one is its without Bloom
///   keeping a second copy of the answer. When that says a number, it is the answer, and a
///   different number is somebody else's pull request wearing the same branch name.
/// - **When the pull request ended.** A pull request cannot have merged before the workspace that
///   produced it existed. This is the cheap half and it is decisive whatever the repository merges
///   with: reachability of the merged head is not, because a merge commit puts that head into the
///   default branch and therefore into every branch cut from it afterwards.
///
/// An open pull request is always accepted. GitHub allows one open pull request per head branch,
/// so an open one matching this branch's name is this branch's.
public enum PullRequestOwnership {
    /// - Parameter startedAt: when the workspace was created. `Workspace.createdAt`.
    /// - Parameter checkedOutAs: the pull request this worktree was checked out from, when git
    ///   records one. See `Git.checkedOutPullRequest`.
    public static func belongs(
        _ pullRequest: PullRequest,
        toWorkspaceStartedAt startedAt: Date,
        checkedOutAs checkedOutNumber: Int?
    ) -> Bool {
        // A worktree that says what it was checked out from has already answered the question,
        // and it outranks the dates: reviewing a pull request that merged last week is a thing
        // people do on purpose, and the strip has to keep saying so.
        if let checkedOutNumber { return pullRequest.number == checkedOutNumber }
        guard let closedAt = pullRequest.closedAt else { return true }
        return closedAt >= startedAt
    }

    /// Which of several pull requests that once had this head branch is this workspace's.
    ///
    /// The same two facts as `belongs` and the same order of precedence, applied to a list rather
    /// than to one answer, because searching by a head that has been deleted is the one lookup
    /// that can come back with more than one. It genuinely does: `gh pr list --head patch-2
    /// --state all` in the repository this bug was reported from answers with three, from three
    /// different people, spread over years.
    ///
    /// Newest first, so that where two of them are equally plausible the recent one wins. That is
    /// the same reasoning as `belongs`: an old pull request wearing a reused name is exactly what
    /// this type exists to refuse.
    ///
    /// - Returns: the number to look up properly, or nil when none of them is this workspace's.
    public static func choose(
        from matches: [PullRequestHeadMatch],
        startedAt: Date,
        checkedOutAs checkedOutNumber: Int?
    ) -> Int? {
        if let checkedOutNumber {
            return matches.contains { $0.number == checkedOutNumber } ? checkedOutNumber : nil
        }
        return matches
            .sorted { $0.number > $1.number }
            .first { $0.closedAt.map { closed in closed >= startedAt } ?? true }?
            .number
    }
}

/// One candidate from a search for a head branch that may no longer exist: enough to choose
/// between several pull requests that wore the same name, and nothing more.
///
/// Deliberately not a `PullRequest`. Nothing here is drawn: it is the two fields
/// `PullRequestOwnership.choose` weighs, read out of `gh pr list`, and the winner is then fetched
/// properly by number. A half-filled `PullRequest` would be a value the strip could accidentally
/// be handed, with `mergeable` reading `UNKNOWN` because that is what `gh pr list` says.
public struct PullRequestHeadMatch: Sendable, Hashable {
    public let number: Int
    /// When it stopped being open, or nil while it is open.
    public let closedAt: Date?

    public init(number: Int, closedAt: Date?) {
        self.number = number
        self.closedAt = closedAt
    }
}

public extension Git {
    /// The pull request this worktree was checked out from, as `gh pr checkout` recorded it.
    ///
    /// `gh pr checkout` sets `branch.<name>.merge` to `refs/pull/<number>/head` for a pull request
    /// it cannot track by branch, which is every fork and, on recent gh, the ordinary case too.
    /// Reading it back costs one `git config` and needs no column of Bloom's own: the association
    /// is written where git already keeps it, by the command that made it.
    ///
    /// **That last sentence holds only while the branch does.** Deleting a branch deletes its
    /// `branch.<name>.*` config with it, so the merge that makes the number necessary is the same
    /// event that destroys git's copy of it: in the workspace this was reported from,
    /// `git config --get-regexp '^branch\.'` no longer mentions the merged branch at all. That is
    /// what `Workspace.pullRequestNumber` is for, and this stays the cheaper answer for as long as
    /// there is a branch to ask about.
    ///
    /// Nil for a worktree on a branch of its own, whose `merge` names a branch on the remote.
    static func checkedOutPullRequest(branch: String, worktree: String) async -> Int? {
        guard isValidBranchName(branch) else { return nil }
        guard let result = try? await run(
            ["config", "--get", "branch.\(branch).merge"], in: worktree
        ), result.ok else { return nil }

        let reference = result.trimmed
        let prefix = "refs/pull/"
        let suffix = "/head"
        guard reference.hasPrefix(prefix), reference.hasSuffix(suffix) else { return nil }
        let digits = reference.dropFirst(prefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}

public extension GitHub {
    /// This workspace's pull request, or nil when the one gh found belongs to an earlier life of
    /// the branch name.
    ///
    /// The only door the app and the tools use, so the ownership question is asked once rather
    /// than at each of the four places that wanted an answer. `pullRequest(forBranch:worktree:)`
    /// stays below it as the raw gh call, which is what `WorkspaceCheckoutResolver` and the
    /// tests want.
    static func pullRequest(
        for workspace: Workspace, maxAge: Duration = .zero
    ) async throws -> PullRequest? {
        try await pullRequest(
            for: workspace, onBranch: await headBranch(of: workspace), maxAge: maxAge
        )
    }

    /// The branch to ask gh about, read from the worktree rather than from the row.
    ///
    /// One local `git rev-parse`, which is nothing beside the `gh` call it is correcting, and it
    /// is the difference between finding a pull request the agent opened from a branch it cut
    /// itself and offering a button that opens a second one. See `PullRequestHead`.
    static func headBranch(of workspace: Workspace) async -> String {
        let checkedOut = try? await Git.currentBranch(of: workspace.path)
        return PullRequestHead.branch(
            recorded: workspace.branch, checkedOut: checkedOut, base: workspace.baseBranch
        )
    }

    private static func pullRequest(
        for workspace: Workspace, onBranch head: String, maxAge: Duration
    ) async throws -> PullRequest? {
        try await snapshot(for: workspace, onBranch: head, maxAge: maxAge)?.pullRequest
    }

    /// This workspace's pull request as gh last described it, asked for three ways.
    ///
    /// **A branch name stops being a question the moment the branch is deleted.** That is the bug
    /// this ladder was built for: a review of pull request #222 was squashed, the branch went on
    /// both sides, the worktree moved to `main`, and every route Bloom had ran out at once. `gh pr
    /// view sentry-worker-src-blob` answered "no pull requests found for branch", the unnamed
    /// fallback answered the same about `main`, and because a nil is deliberately never written
    /// over a known pull request (see `WorkspaceModel.refreshPullRequest`, and that rule is
    /// right), the strip went on showing the snapshot taken before the merge: open, eighteen
    /// checks passed, and a live Squash and merge button over work GitHub had already landed.
    ///
    /// So, three routes, in order, each one only asked when the one above it came away empty:
    ///
    /// 1. **By branch.** What everything did before, and still the answer nearly every time. It
    ///    finds merged pull requests too, so long as the ref still resolves.
    /// 2. **By the number on the row.** Exact, and it needs no ref at all. Not gated on
    ///    `PullRequestOwnership`, and that is deliberate: the number IS the ownership answer,
    ///    the thing `belongs` spends two heuristics approximating. Gating it would refuse a
    ///    workspace opened to review a pull request that merged last month, which is the one case
    ///    `checkedOutAs` was added to allow and which is precisely when that git config is gone.
    /// 3. **By searching for the head.** `gh pr list --head <branch> --state all` reads the head
    ///    ref recorded on the pull request, which is history rather than a ref, so it answers
    ///    after the branch is deleted. This is the recovery route for a row whose number was never
    ///    written down, which is every workspace that predates `Workspace.pullRequestNumber`. It
    ///    IS gated, because a name can be reused and this one comes back with a list.
    ///
    /// Route 3 only runs when the recorded branch is gone locally, and that gate is what keeps it
    /// from costing anything. Without it every poll of every workspace with no pull request yet,
    /// which is most of them, would spend a second `gh` process finding nothing. A branch that is
    /// still here is a branch `gh pr view` can still be asked about; a branch that has been
    /// deleted is the state Bloom's own merge leaves behind, and the only state route 3 helps in.
    internal static func snapshot(
        for workspace: Workspace, onBranch head: String, maxAge: Duration
    ) async throws -> PullRequestSnapshot? {
        if let found = try await snapshot(
            forBranch: head, worktree: workspace.path, maxAge: maxAge
        ), await owns(found.pullRequest, workspace: workspace, onBranch: head) {
            return found
        }

        if let number = workspace.pullRequestNumber,
           let found = await snapshot(forNumber: number, worktree: workspace.path, maxAge: maxAge) {
            return found
        }

        let branchIsGone = await !Git.branchExists(head, in: workspace.path)
        guard branchIsGone else { return nil }

        let matches = await pullRequestsWithHead(head, worktree: workspace.path)
        guard let chosen = PullRequestOwnership.choose(
            from: matches,
            startedAt: workspace.createdAt,
            checkedOutAs: await Git.checkedOutPullRequest(branch: head, worktree: workspace.path)
        ) else { return nil }
        return await snapshot(forNumber: chosen, worktree: workspace.path, maxAge: maxAge)
    }

    /// This workspace's checks, which are the checks of this workspace's pull request.
    ///
    /// The same gate, because they come out of the same `gh pr view`: a rollup drawn for a pull
    /// request that merged before this workspace existed is a green tick over work nobody has run
    /// anything against.
    ///
    /// One snapshot, not two. Asking for the pull request and then for the checks landed on the
    /// same cache key, and `maxAge` is zero for the only caller, which never hits, so the Checks
    /// tab made two identical `gh pr view` round trips every twenty seconds and threw one payload
    /// away.
    static func checks(for workspace: Workspace, maxAge: Duration = .zero) async throws -> [CheckRun] {
        // The same branch both times, or the rollup is read for one branch and gated on another.
        let head = await headBranch(of: workspace)
        guard let found = try await snapshot(
            for: workspace, onBranch: head, maxAge: maxAge
        ) else { return [] }
        return found.runs
    }

    /// Whether the pull request gh found under this branch name is this workspace's.
    private static func owns(
        _ pullRequest: PullRequest, workspace: Workspace, onBranch head: String
    ) async -> Bool {
        let checkedOut = await Git.checkedOutPullRequest(branch: head, worktree: workspace.path)
        return PullRequestOwnership.belongs(
            pullRequest, toWorkspaceStartedAt: workspace.createdAt, checkedOutAs: checkedOut
        )
    }
}
