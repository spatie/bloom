import Foundation

/// What a worktree has changed, counted the way the inspector and the sidebar show it.
///
/// Every call in this file runs git with `-z` and parses the bytes rather than the text. A path
/// is a byte string that may hold a tab or a newline and need not decode as UTF-8 at all, and
/// git's default output C-quotes anything that is not plain ASCII, so splitting the decoded
/// `String` on tabs gets both wrong.
///
/// `LocalWork` is here rather than in `Git+Safety.swift` because it is the cheap question, the
/// one a pull request strip can afford to ask beside a poll. Its own comment has the difference.
///
/// `ChangedFile` below is one entry of the answer: a path, what happened to it, and the counts.
public struct ChangedFile: Identifiable, Sendable, Hashable, Codable {
    public enum Change: String, Sendable, Codable {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case untracked = "?"
    }

    public var path: String
    public var oldPath: String?
    public var change: Change
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool
    /// An untracked file exceeded the caller's counting budget, so its line counts are unknown.
    public var contentRevision: String?
    public var hasIncompleteStats: Bool

    public var id: String { path }

    public var filename: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }

    public init(
        path: String,
        oldPath: String? = nil,
        change: Change,
        additions: Int = 0,
        deletions: Int = 0,
        isBinary: Bool = false,
        hasIncompleteStats: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.change = change
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.hasIncompleteStats = hasIncompleteStats
    }
}
