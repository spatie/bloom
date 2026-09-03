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
/// Nothing here throws or reports. A sidebar mark is not the place to learn that gh is signed
/// out: the row simply falls back to what git alone knows.
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

    private var pullRequests: [WorkspaceID: PullRequest] = [:]

    /// The tail of the lookup queue. Each new lookup waits for the previous one, which is what
    /// turns twelve rows appearing at once into twelve sequential `gh` calls instead of twelve
    /// concurrent ones.
    private var queue: Task<Void, Never> = Task {}

    func pullRequest(for workspaceID: WorkspaceID) -> PullRequest? {
        pullRequests[workspaceID]
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
    /// Nil is written here where `refresh` below refuses to write it, and the difference is the
    /// whole reason both exist. `refresh` is a poll behind a row nobody is looking at, where nil
    /// means "gh did not answer" at least as often as it means "there is no pull request", and
    /// making the mark flicker on a slow network is worse than showing a stale one. This is a
    /// deliberate read for the workspace somebody is looking at, and there nil is an answer.
    func set(_ pullRequest: PullRequest?, for workspaceID: WorkspaceID) {
        // Writing an equal value still invalidates every row reading this dictionary.
        guard pullRequests[workspaceID] != pullRequest else { return }
        pullRequests[workspaceID] = pullRequest
    }

    /// Drops what is remembered about one workspace, for a caller that knows the answer is now
    /// about a branch this workspace is no longer on.
    ///
    /// Needed because `refresh` deliberately never clears: it treats nil as "gh could not answer"
    /// rather than "there is no pull request", so a stale entry outlives every poll. That is the
    /// right trade for a slow network and the wrong one after `AppModel.continueAfterMerge` moves
    /// the worktree to a fresh branch, where the merged pull request in here would keep marking
    /// the row for the rest of the session.
    func forget(_ workspaceID: WorkspaceID) {
        pullRequests[workspaceID] = nil
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
            || pullRequests[workspace.id] != nil else { return }
        guard await GitHubAvailability.shared.isReady() else { return }

        let id = workspace.id
        let asked = workspace

        let previous = queue
        let lookup = Task { @MainActor in
            await previous.value
            let fresh = await GitHubBridge.pullRequest(for: asked, maxAge: Self.maxAge)
            // Nil is both "there is no pull request" and "gh could not answer", so the last known
            // answer is kept rather than making the mark flicker back to a plain branch whenever
            // the network is slow.
            guard let fresh else { return }
            await PullRequestNumber.record(fresh, for: asked, in: store)
            // Writing an equal value still invalidates every row reading this dictionary, and a
            // poll that changed nothing is the common case.
            guard self.pullRequests[id] != fresh else { return }
            self.pullRequests[id] = fresh
        }
        queue = lookup
        await lookup.value
    }
}
