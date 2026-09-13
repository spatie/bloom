import Foundation

public struct TurnCheckpoint: Codable, Sendable, Equatable, Identifiable {
    public let id: GitSnapshotID
    public let sessionID: SessionID
    public let startSeq: Int
    public var endSeq: Int?
    public let before: GitSnapshot
    public var after: GitSnapshot?
    public var providerTurnID: String?

    public init(sessionID: SessionID, startSeq: Int, before: GitSnapshot) {
        self.id = before.id
        self.sessionID = sessionID
        self.startSeq = startSeq
        self.before = before
    }
}

/// Files and provider history cannot commit atomically. Keeping the recovery snapshot and the
/// last completed step makes a failure visible after relaunch instead of silently losing context.
public struct CheckpointRewind: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable {
        case prepared, filesRestored, providerReverted, complete, failed
    }
    public let token: UUID
    public let checkpoint: TurnCheckpoint
    public let recovery: GitSnapshot?
    public let restoringFiles: Bool
    public var stage: Stage
    public var failure: String?

    public init(checkpoint: TurnCheckpoint, recovery: GitSnapshot?, restoringFiles: Bool, token: UUID = UUID()) {
        self.token = token
        self.checkpoint = checkpoint
        self.recovery = recovery
        self.restoringFiles = restoringFiles
        self.stage = .prepared
    }
}
