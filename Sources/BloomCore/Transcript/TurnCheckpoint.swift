import Foundation

public struct TurnCheckpoint: Codable, Sendable, Equatable, Identifiable {
    public let id: GitSnapshotID
    public let sessionID: SessionID
    public let startSeq: Int
    public var endSeq: Int?
    public let before: GitSnapshot
    public var after: GitSnapshot?
    /// The net changes from `before` to `after`, kept once read so a reopened conversation draws
    /// each footer at its full height on the first frame instead of waiting on git.
    public var files: [TurnFile]?

    public init(sessionID: SessionID, startSeq: Int, before: GitSnapshot) {
        self.id = before.id
        self.sessionID = sessionID
        self.startSeq = startSeq
        self.before = before
    }
}
