import Foundation
import BloomClient

/// Worktree and staging are distinct snapshots. Restoring only a worktree tree into both would
/// turn every untracked file into a staged addition and lose the owner's partial staging.
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
