import Foundation

/// One worktree cut at a time in any one repository.
///
/// `WorkspaceManager.createWorkspace` reads the repository's branches, works out a name nothing
/// has taken, picks a directory nothing occupies, and only then runs `git worktree add`. Every one
/// of those is a read followed by an act, with awaits in between, so two creates running at once
/// in the same project both look at the same repository and both decide on the same free branch
/// and the same free directory. The second `git worktree add` then fails with git's own words
/// about a branch that already exists, after the first has already been reported as a success.
///
/// Nothing noticed because until now creating a workspace meant a person filling in a sheet, and a
/// person cannot press Create twice in the same millisecond. An agent starting two workspaces from
/// one turn can, and will.
///
/// **Not `SingleFlight`**, which is the other non-reentrancy type in here and the obvious thing to
/// reach for. That one coalesces: a caller arriving mid-flight is handed the running call's result
/// and no second run happens at all. That is right when both callers are asking the same question
/// of the same data, and it is exactly wrong here, because two creates are two requests for two
/// different worktrees. Coalescing them would report success twice and cut one worktree. This
/// serialises instead: everybody gets their own run, one after another. `SingleFlight` is also
/// `@MainActor`, and none of this is.
///
/// Keyed on the repository path, because that is what the contention is over: two creates in two
/// different projects share no branch list, no worktree directory and no git index, and making
/// them queue behind each other would be a made up cost.
public actor WorktreeCutQueue {
    public static let shared = WorktreeCutQueue()

    /// The last run queued for each repository, as something to wait on.
    ///
    /// Never cleared. A finished `Task<Void, Never>` holds nothing, there is one entry per project
    /// the user has ever created a workspace in during this launch, and every scheme for clearing
    /// them reopens the race it is here to close: the entry can only be removed after the run it
    /// describes has finished, and a caller arriving in that window would find nothing to wait for.
    private var tails: [String: Task<Void, Never>] = [:]

    public init() {}

    /// Runs `work` once every run already queued for this repository has finished.
    public func cut<T: Sendable>(
        in repo: String,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = tails[repo]
        let run = Task<T, Error> {
            await previous?.value
            return try await work()
        }
        // What the next caller waits on, and deliberately a second task that cannot fail. A create
        // that throws still has to let the queue move: one repository whose `git worktree add` went
        // wrong must not be a repository nothing can ever be created in again.
        let finished = Task<Void, Never> { _ = try? await run.value }
        tails[repo] = finished
        return try await run.value
    }
}
