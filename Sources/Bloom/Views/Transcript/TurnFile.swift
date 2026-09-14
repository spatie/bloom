import Foundation
import BloomCore

/// A file changed during a turn. Recorded snapshots supply net counts; old turns use tool calls.
struct TurnFile: Identifiable, Hashable, Sendable {
    /// Snapshot paths are repository-relative; older tool events can carry absolute paths.
    var path: String
    var additions: Int
    var deletions: Int

    var id: String { path }
    var name: String { ToolPresenter.basename(path) }

    /// What a reader is shown: the path relative to the worktree, the same form the inspector's
    /// changed files and the review tabs use.
    ///
    /// A turn's chips used to carry the absolute path in their tooltip, which on this machine is
    /// four lines of scratch directory in front of `src/app.js`, for a file the inspector six
    /// inches away was calling `src/app.js`. A file outside the worktree keeps its absolute path,
    /// because for that one the directory is the answer rather than the noise.
    func display(in worktree: String) -> String {
        FilePathGuess.relative(path, to: worktree) ?? path
    }
}
