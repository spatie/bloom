import Foundation

public struct TurnCheckpoint: Codable, Sendable, Equatable, Identifiable {
    public let id: GitSnapshotID
    public let sessionID: SessionID
    public let startSeq: Int
    public var endSeq: Int?
    public let before: GitSnapshot
    public var after: GitSnapshot?

    public init(sessionID: SessionID, startSeq: Int, before: GitSnapshot) {
        self.id = before.id
        self.sessionID = sessionID
        self.startSeq = startSeq
        self.before = before
    }
}
