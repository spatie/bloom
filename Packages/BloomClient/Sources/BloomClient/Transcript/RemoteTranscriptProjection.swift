import Foundation

/// A presentation row retains its original message identity when its tool result arrives.
public struct RemoteTranscriptRow: Identifiable, Equatable, Sendable {
    public var id: Int64 { message.id }
    public let message: RemoteMessage
    public var toolResult: RemoteMessage?

    public init(message: RemoteMessage, toolResult: RemoteMessage? = nil) {
        self.message = message
        self.toolResult = toolResult
    }
}

public enum RemoteTranscriptProjection {
    /// Never modifies the source buffer. Event cursors and replay continue to use all messages.
    public static func rows(messages: [RemoteMessage]) -> [RemoteTranscriptRow] {
        var rows: [RemoteTranscriptRow] = []
        var indexByRefID: [String: Int] = [:]
        rows.reserveCapacity(messages.count)
        for message in messages {
            guard TranscriptVisibility.isVisible(kind: message.kind, payload: message.payload) else { continue }
            if let index = TranscriptToolPairing.resultIndex(kind: message.kind, refID: message.refID, indexByRefID: indexByRefID) {
                rows[index].toolResult = message
                continue
            }
            TranscriptToolPairing.recordCall(kind: message.kind, refID: message.refID, rowIndex: rows.count, indexByRefID: &indexByRefID)
            rows.append(RemoteTranscriptRow(message: message))
        }
        return rows
    }
}
