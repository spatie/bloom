import SwiftUI
import Observation
import BloomCore

/// The pull request behind each sidebar row, shared by every row that asks.
///
/// The sidebar wants GitHub's opinion of a dozen branches at once, and each opinion costs a
/// subprocess. Three things keep that affordable: rows share one answer per workspace, the
/// lookups run one at a time rather than as a burst of a dozen `gh` processes, and a branch that
/// has produced no changes at all is never asked about, because a branch with nothing on it
/// cannot have a pull request.
///
/// Failed reads preserve the last good mark. The inspector reads the accompanying failure
/// from this same state, so the explanation and the content cannot disagree.
@MainActor
@Observable
final class WorkspacePullRequests {
    static let shared = WorkspacePullRequests()

    /// How often a visible row asks again. GitHub's own state changes on CI's schedule, not the
    /// user's, and the inspector polls far faster for the workspace actually being looked at.
    static let refreshInterval = Duration.seconds(120)

    /// Slightly under the refresh interval, so two rows waking together share one lookup while a
    /// genuine poll a full interval later is never served from the cache.
    private static let maxAge = Duration.seconds(110)

    private var states: [WorkspaceID: PullRequestRefreshState] = [:]
    @ObservationIgnored private var generations: [WorkspaceID: UInt64] = [:]

    func failure(for workspaceID: WorkspaceID) -> GitHubReadFailure? { states[workspaceID]?.failure }

    func record(_ read: PullRequestRead, for workspaceID: WorkspaceID) {
        generations[workspaceID, default: 0] &+= 1
        var state = states[workspaceID] ?? PullRequestRefreshState()
        state.record(read)
        if states[workspaceID] != state { states[workspaceID] = state }
    }

    /// The tail of the lookup queue. Each new lookup waits for the previous one, which is what
    /// turns twelve rows appearing at once into twelve sequential `gh` calls instead of twelve
    /// concurrent ones.
    private var queue: Task<Void, Never> = Task {}

    func pullRequest(for workspaceID: WorkspaceID) -> PullRequest? {
        states[workspaceID]?.pullRequest
    }

    /// Records an answer somebody else went and got, including nil.
    ///
    /// **This is what makes the class the one holder of the fact.** `WorkspaceModel` used to keep
    /// a `pullRequest` of its own with a 30 second max age beside this one's 110, and the two were
    /// read by different surfaces: the sidebar glyph and the Home rail from here, the title bar
    /// strip, the pull request bar and `InspectorTab.available(for:)` from the model. For one open
    /// workspace those could disagree for up to two minutes about whether a pull request existed.
    /// This is the two-blues bug one layer down: not two places deciding a colour, but two places
    /// holding the fact the colour comes from.
    ///
    /// Only a successful read calls this. Failed reads go through record and retain content.
    func set(_ pullRequest: PullRequest?, for workspaceID: WorkspaceID) {
        record(.current(pullRequest), for: workspaceID)
    }

    /// Drops what is remembered about one workspace, for a caller that knows the answer is now
    /// about a branch this workspace is no longer on.
    ///
    /// Also invalidates a queued read of the old branch, which must not repopulate this entry
    /// after the workspace has continued onto a new branch.
    func forget(_ workspaceID: WorkspaceID) {
        generations[workspaceID, default: 0] &+= 1
        states[workspaceID] = nil
    }

    /// Keeps one workspace's answer fresh for as long as its row is on screen.
    ///
    /// - Parameter store: where a number found here is written down, so a merged pull request
    ///   whose branch has been deleted is still findable after a relaunch. See
    ///   `Workspace.pullRequestNumber`. Nil before the database has opened, which costs nothing:
    ///   the next poll records it.
    func track(_ workspace: Workspace, store: Store?) async {
        while !Task.isCancelled {
            await refresh(workspace, store: store)
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    private func refresh(_ workspace: Workspace, store: Store?) async {
        // A worktree identical to its base has nothing to open a pull request for. Skipping it
        // is what keeps a project full of fresh workspaces from launching a process per row.
        //
        // A recorded number is the third reason to ask, and without it a merged workspace was
        // invisible to this poll for the whole of the next launch: the merge leaves the worktree
        // on the base with nothing in the diff, so `hasDiff` is false, and a fresh launch has
        // nothing in the cache yet. The row went back to a plain branch until somebody opened the
        // workspace and the band asked on its own.
        guard workspace.hasDiff
            || workspace.pullRequestNumber != nil
            || states[workspace.id]?.pullRequest != nil else { return }

        let id = workspace.id
        let asked = workspace
        let generation = generations[id, default: 0]

        let previous = queue
        let lookup = Task { @MainActor in
            await previous.value
            guard !Task.isCancelled, self.generations[id, default: 0] == generation else { return }
            let read = await GitHubBridge.readPullRequest(for: asked, maxAge: Self.maxAge)
            guard !Task.isCancelled, self.generations[id, default: 0] == generation else { return }
            self.record(read, for: id)
            guard case .current(let fresh) = read else { return }
            guard let fresh else { return }
            await PullRequestNumber.record(fresh, for: asked, in: store)
        }
        queue = lookup
        await withTaskCancellationHandler { await lookup.value } onCancel: { lookup.cancel() }
    }
}
