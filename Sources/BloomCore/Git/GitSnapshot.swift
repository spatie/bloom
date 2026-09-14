import Foundation

/// Worktree and staging are distinct snapshots. Only the worktree tree is read now, by a turn's
/// footer; the two staging refs were for restoring files, which was removed. They are still
/// written by capture and removed by `Git.deleteSnapshot`, so snapshots taken before and after
/// that removal are pruned by the same code.
public struct GitSnapshot: Codable, Sendable, Equatable {
    public let id: GitSnapshotID
    public let sessionID: SessionID
    public let createdAt: Date
    public let indexWasPresent: Bool?
    public var worktreeRef: String { "refs/bloom/checkpoints/\(id)/worktree" }
    public var indexRef: String { "refs/bloom/checkpoints/\(id)/index" }
    public var rawIndexRef: String { "refs/bloom/checkpoints/\(id)/raw-index" }

    public init(id: GitSnapshotID = .new(), sessionID: SessionID, createdAt: Date = Date(), indexWasPresent: Bool? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.indexWasPresent = indexWasPresent
    }
}

public struct SnapshotFailure: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}
