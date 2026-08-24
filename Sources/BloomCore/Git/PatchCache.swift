import Foundation

/// The patches a workspace has already asked git for, and the rule for when one may be reused.
///
/// **Returning to the review tab used to spawn a `git diff` every time.** The pane is destroyed
/// when the centre column switches tab and built again on the way back, so flicking between a
/// conversation and the changes ran the same `git diff -M <base> -- <path>` over and over, on a
/// worktree nothing had touched in between. `WorkspaceModel.pullRequestArrivalMaxAge` is the same
/// bug already fixed once, for `gh auth status` and `gh pr view`, and its comment carries the
/// measurement: 640ms to 1.1s per arrival, all of it repeated by flicking between two workspaces.
///
/// # What makes an answer reusable
///
/// Everything the command is built from is in `Key`, so an entry can only ever be handed back for
/// a question byte for byte identical to the one it answered: the worktree, the base branch, the
/// path, what happened to that path (an untracked file is diffed against `/dev/null` and a tracked
/// one against a merge base, which are two different commands), and the scope the tab is set to.
///
/// `generation` is `WorkspaceModel.changesGeneration`, which counts refreshes that LANDED rather
/// than refreshes that moved the list. That is deliberately the strictest thing available: an
/// agent rewording a line one for one leaves a file's counts, and with them the whole
/// `ChangedFile`, exactly where they were, so the counts cannot be trusted to say a patch is
/// still current. The consequence is worth stating plainly: the changed file poll runs every six
/// seconds, so an entry is good for at most that long. It is not a cache that saves a reader who
/// comes back a minute later, and it is not meant to be. It is the one that saves the flick.
public struct PatchCache: Sendable {
    /// What a held patch is the answer to. Every field is part of the git command that produced
    /// it, plus the generation that says the worktree has not been looked at again since.
    public struct Key: Hashable, Sendable {
        public var worktree: String
        public var base: String
        public var file: String
        public var change: ChangedFile.Change
        public var scope: DiffScope
        public var generation: Int

        public init(
            worktree: String,
            base: String,
            file: ChangedFile,
            scope: DiffScope,
            generation: Int
        ) {
            self.worktree = worktree
            self.base = base
            self.file = file.path
            self.change = file.change
            self.scope = scope
            self.generation = generation
        }
    }

    /// How many patches are held at once.
    ///
    /// A dozen, which is more files than anybody clicks through between two refreshes and few
    /// enough that a repository whose diffs are megabytes cannot quietly become the largest thing
    /// in the process. The generation rule below is what does the real work; this is the backstop
    /// for a reader moving fast through a large review inside one generation.
    public static let capacity = 12

    private var patches: [Key: String] = [:]
    /// Keys oldest first, so the entry evicted for capacity is the one least recently stored.
    private var order: [Key] = []

    public init() {}

    public var count: Int { patches.count }

    public func patch(for key: Key) -> String? {
        patches[key]
    }

    /// Files an answer, and throws away everything the answer supersedes.
    ///
    /// A new generation means git has looked at the worktree again, so every patch from an older
    /// one is a claim about a worktree nobody has checked. They go in one sweep rather than
    /// waiting to be evicted by capacity, because a stale patch is not merely useless: held in a
    /// map keyed on a generation nothing will ask for again, it is a leak.
    public mutating func store(_ patch: String, for key: Key) {
        if patches[key] == nil || order.last != key {
            order.removeAll { $0 == key }
            order.append(key)
        }
        patches[key] = patch

        let superseded = order.filter { $0.generation != key.generation }
        for stale in superseded { patches[stale] = nil }
        order.removeAll { $0.generation != key.generation }

        while order.count > Self.capacity {
            let oldest = order.removeFirst()
            patches[oldest] = nil
        }
    }
}
