import Foundation
import Synchronization

/// The project's standing permission rules, as one chat reaches them.
///
/// **Both runners held this four times over, byte for byte.** `AgentRunner` and `CodexRunner` each
/// carried a `cachedRepoID` property, a `repoID()` under the same comment about Ask Bloom having
/// no project behind it, a `matchingGrants(for:)` whose three lines were identical, and the loop
/// at the end of `answer` that writes what a project-scope decision granted, under two copies of
/// the same paragraph about doing Bloom's bookkeeping after the agent has been unblocked. That is
/// four rules stated twice, and the way a pair like that drifts is that somebody fixes one of
/// them.
///
/// `PermissionGrant.all` is the precedent and its head makes the argument this file extends:
/// `SessionRunner` is right that runner surface is not shared, because the protocols are not, but
/// none of this is protocol. It is Bloom deciding what it already approved, in Bloom's own tables,
/// with no backend vocabulary anywhere in it.
///
/// A `Sendable` class with a lock rather than an actor, for the reason `PendingAsks` gives: it is
/// held by two actors that reach it from inside their own isolation, and an `await` to read a
/// cached id would open a suspension point in the middle of paths that are counting them. Two
/// lookups racing the empty cache both ask the store and both write the same answer, which is what
/// the actor-isolated version they replace also did: the query is behind a suspension point there
/// too, so the cache was never a claim.
final class SessionGrants: Sendable {
    private let store: Store
    /// The workspace this chat belongs to, or nil for a chat with no worktree.
    ///
    /// Captured once rather than read off the session on each call. A session does not move
    /// between workspaces, and the runners were reading `session.workspaceID` off a value they had
    /// been carrying since the workspace was opened, so this is the same fact fixed earlier.
    private let workspaceID: WorkspaceID?
    private let cachedRepoID = Mutex<RepoID?>(nil)

    init(store: Store, workspaceID: WorkspaceID?) {
        self.store = store
        self.workspaceID = workspaceID
    }

    /// What this session's workspace belongs to. Looked up rather than held, because a runner
    /// outlives any particular view and the answer never changes.
    func repoID() async -> RepoID? {
        if let cached = cachedRepoID.withLock({ $0 }) { return cached }
        // Nil for a chat with no worktree, which is Ask Bloom: there is no project behind it, so
        // there is no project scope to grant in it either. See `PermissionScopeOffer`.
        guard let workspaceID,
              let workspace = try? await store.workspace(id: workspaceID) else { return nil }
        cachedRepoID.withLock { $0 = workspace.repoID }
        return workspace.repoID
    }

    /// The project's granted rules that between them answer this ask, or nil when nothing there
    /// covers it.
    ///
    /// Read from the store on every ask rather than cached. That is what makes revoking a rule
    /// take effect on the next question instead of on the next launch, and asks are rare enough
    /// that one query each is not worth a cache that could go stale in the wrong direction.
    func matching(_ ask: PermissionAsk) async -> [PermissionGrant]? {
        guard ask.canWiden, let repoID = await repoID() else { return nil }
        guard let grants = try? await store.permissionGrants(repoID: repoID) else { return nil }
        return PermissionGrantIndex.match(ask: ask, grants: grants)
    }

    /// Note that these grants answered a question, so the panel can say when each was last used.
    ///
    /// Quiet on failure, and deliberately: the question has already been answered and the turn has
    /// already moved on, so a database that refuses a usage stamp must not turn a settled ask into
    /// an error.
    func recordUse(of grants: [PermissionGrant]) async {
        for grant in grants {
            try? await store.recordPermissionGrantUse(id: grant.id)
        }
    }

    /// Write down what a person's decision granted for the rest of this project.
    ///
    /// Called after the agent has been unblocked, by both runners, and that ordering is the point:
    /// a database that refuses the write cannot leave a turn hanging on a question that was
    /// already answered. `PermissionGrant.all` returns nothing at all for a decision that was not
    /// a project one, so this is a no-op for the ordinary once-only answer.
    func record(_ decision: PermissionDecision, from ask: PermissionAsk) async {
        guard let repoID = await repoID() else { return }
        for grant in PermissionGrant.all(granting: decision, from: ask, repoID: repoID) {
            _ = try? await store.upsert(grant)
        }
    }
}
