import Foundation

public struct TranscriptRewindBackup: Codable, Sendable {
    public let checkpointID: GitSnapshotID
    public let messages: [Message]
    public let prompt: String
    public let originalDraft: String

    public init(checkpointID: GitSnapshotID, messages: [Message], prompt: String, originalDraft: String) {
        self.checkpointID = checkpointID
        self.messages = messages
        self.prompt = prompt
        self.originalDraft = originalDraft
    }

    public static func key(sessionID: SessionID) -> String { "turn.rewind.transcript.\(sessionID)" }
}
