import Foundation

/// When the pull request number on a workspace row is worth writing, and what to write.
///
/// The row holds a number so that a lookup has something to ask about after the branch has gone.
/// See `Workspace.pullRequestNumber` for the bug that forced the column; this is the half that
/// keeps it filled in, and it is a separate type because the decision is small, has three callers
/// and is the sort of thing that goes wrong quietly.
///
/// **The newest answer wins.** A workspace does not always keep the same pull request: an agent
/// that merges, cuts a fresh branch and opens a second one leaves the row naming the first, and a
/// row that goes on naming a merged pull request forever is the same class of bug as the stale
/// snapshot this whole change is about, one launch later and harder to see. So a found pull
/// request whose number differs from the recorded one replaces it, whatever either of them says
/// about being merged. `AppModel.continueAfterMerge` clears the column for the same reason,
/// through `continueOnNewBranch`, and does not wait for a lookup to correct it.
///
/// Nothing is written for a nil answer. Nil is "gh could not answer" at least as often as it is
/// "there is no pull request", which is the rule `WorkspacePullRequests` already holds the cache
/// to, and clearing an exact number on the strength of a slow network would throw away the one
/// fact that survives a relaunch.
public enum PullRequestNumber {
    /// - Parameter found: what the lookup answered, or nil when it answered nothing.
    /// - Parameter recorded: `Workspace.pullRequestNumber` as it stands.
    /// - Returns: the number to write, or nil when the row is already right or there is nothing
    ///   to say.
    public static func toRecord(found: PullRequest?, recorded: Int?) -> Int? {
        // Zero is a real value rather than a hypothetical: `GitHub.decodePullRequest` reads a
        // payload with no `number` in it as 0, which an older gh produces, and a 0 written here
        // would be asked about by `gh pr view 0` on every poll for the rest of the row's life.
        guard let found, found.number > 0, found.number != recorded else { return nil }
        return found.number
    }

    /// Writes the number down, when the answer says something the row does not.
    ///
    /// Silent about failure on purpose. This runs behind a poll nobody asked for, and a workspace
    /// archived or deleted between the lookup and the write is an ordinary race rather than
    /// something to report: the store writes nothing for a row that is not there, and the next
    /// lookup that finds anything will try again.
    public static func record(_ found: PullRequest?, for workspace: Workspace, in store: Store?) async {
        guard let store, let number = toRecord(found: found, recorded: workspace.pullRequestNumber) else {
            return
        }
        // One named column rather than a whole `Workspace` through `upsert`, for the reason in
        // `Store`'s head: the value in hand was read before a `gh` round trip that can take
        // seconds, and writing it back would carry every other column across that gap. The store
        // compares before it writes, so a poll that answers the number already on the row costs
        // one read and announces nothing.
        try? await store.recordPullRequestNumber(number, workspaceID: workspace.id)
    }
}
