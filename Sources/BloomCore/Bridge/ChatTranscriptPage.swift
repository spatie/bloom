import Foundation

/// Sequence numbers survive new messages arriving between reads. The content offset also lets
/// one enormous tool result cross the page boundary without either losing its tail or sending an
/// unbounded reply. A cursor includes the session so it cannot silently skip a different chat.
enum ChatTranscriptPage {
    static let characterLimit = 32_000

    struct Cursor {
        var sessionID: SessionID
        var seq: Int = 0
        var offset: Int = 0

        init(sessionID: SessionID, seq: Int = 0, offset: Int = 0) {
            self.sessionID = sessionID
            self.seq = seq
            self.offset = offset
        }

        init?(_ raw: String, sessionID: SessionID) {
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == sessionID.rawValue,
                  let seq = Int(parts[1]), seq >= 0, seq < Int.max,
                  let offset = Int(parts[2]), offset >= 0 else { return nil }
            self.init(sessionID: sessionID, seq: seq, offset: offset)
        }

        var rawValue: String { "\(sessionID.rawValue):\(seq):\(offset)" }
    }

    struct Page {
        var messages: [JSONValue]
        var nextCursor: Cursor?
    }

    struct StaleCursor: LocalizedError {
        var errorDescription: String? { "The message at that cursor has changed. Omit 'cursor' to start again." }
    }

    static func make(messages: [Message], cursor: Cursor, limit: Int) throws -> Page {
        var rows: [JSONValue] = []
        var remaining = characterLimit
        if cursor.offset > 0, messages.first?.seq != cursor.seq { throw StaleCursor() }

        for message in messages {
            let offset = message.seq == cursor.seq ? cursor.offset : 0
            let position = Cursor(sessionID: cursor.sessionID, seq: message.seq, offset: offset)
            if rows.count == limit || remaining == 0 {
                return Page(messages: rows, nextCursor: position)
            }
            let content = content(of: message)
            guard offset <= content.count else { throw StaleCursor() }
            let chunk = String(content.dropFirst(offset).prefix(remaining))
            let complete = offset + chunk.count == content.count
            rows.append(.object([
                "seq": .integer(message.seq),
                "kind": .string(message.kind.rawValue),
                "created_at": .string(message.createdAt.ISO8601Format()),
                "content": .string(chunk),
                "offset": .integer(offset),
                "complete": .bool(complete),
            ]))
            remaining -= chunk.count
            if !complete {
                return Page(messages: rows, nextCursor: Cursor(
                    sessionID: cursor.sessionID, seq: message.seq, offset: offset + chunk.count
                ))
            }
        }
        return Page(messages: rows, nextCursor: nil)
    }

    private static func content(of message: Message) -> String {
        if message.kind == .user {
            let text = UserTurnPrompt.text(in: message.payload)
            if !text.isEmpty { return text }
        }
        if message.kind == .crew, let crew = CrewMessage.decode(message.payload) { return crew.text }
        let raw = String(decoding: message.payload, as: UTF8.self)
        // The event decoder reads the first block, as the UI does. Preserve unfamiliar or
        // multi-block envelopes whole instead of losing any of their content here.
        if message.kind == .assistantText || message.kind == .thinking,
           JSONValue.parse(message.payload)?["message"]?["content"]?.arrayValue?.count == 1 {
            switch AgentEvent.decode(line: raw) {
            case .assistantText(let block), .thinking(let block): return block.text
            default: break
            }
        }
        return raw
    }
}
