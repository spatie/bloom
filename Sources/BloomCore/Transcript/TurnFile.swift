import Foundation

/// A file changed during a turn. Recorded snapshots supply net counts; old turns use tool calls.
public struct TurnFile: Identifiable, Hashable, Sendable, Codable {
    /// Snapshot paths are repository-relative; older tool events can carry absolute paths.
    public var path: String
    public var additions: Int
    public var deletions: Int

    public var id: String { path }
    public var name: String { ToolPresenter.basename(path) }

    public init(path: String, additions: Int, deletions: Int) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
    }

    public init(_ changed: ChangedFile) {
        self.init(path: changed.path, additions: changed.additions, deletions: changed.deletions)
    }

    /// What a reader is shown: the path relative to the worktree, the same form the inspector's
    /// changed files and the review tabs use.
    ///
    /// A turn's chips used to carry the absolute path in their tooltip, which on this machine is
    /// four lines of scratch directory in front of `src/app.js`, for a file the inspector six
    /// inches away was calling `src/app.js`. A file outside the worktree keeps its absolute path,
    /// because for that one the directory is the answer rather than the noise.
    public func display(in worktree: String) -> String {
        FilePathGuess.relative(path, to: worktree) ?? path
    }
}
