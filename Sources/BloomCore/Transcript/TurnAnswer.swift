import Foundation

/// Codex's successful result carries no summary. Recover the answer from the saved prose so
/// the footer can copy it in old conversations as well as newly completed turns.
public enum TurnAnswer {
    public struct Row: Sendable {
        public var seq: Int
        public var kind: MessageKind
        public var payload: Data
        public var isNested: Bool

        public init(seq: Int, kind: MessageKind, payload: Data, isNested: Bool = false) {
            self.seq = seq
            self.kind = kind
            self.payload = payload
            self.isNested = isNested
        }
    }

    /// A lazy projection avoids copying the session. Locate this footer in sequence order, then
    /// decode only assistant rows in its own turn, ignoring tools and subagent conversations.
    public static func text<Rows: RandomAccessCollection>(
        summary: String, rows: Rows, endingAt seq: Int
    ) -> String where Rows.Element == Row, Rows.Index == Int {
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return summary }

        var low = rows.startIndex
        var high = rows.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if rows[middle].seq < seq { low = middle + 1 } else { high = middle }
        }

        var index = low
        while index > rows.startIndex {
            index -= 1
            let row = rows[index]
            if row.isNested { continue }
            switch row.kind {
            case .user, .crew, .result:
                return ""
            case .assistantText:
                guard case .assistantText(let block)? = AgentEvent.decode(
                    line: String(decoding: row.payload, as: UTF8.self)
                ), !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                return block.text
            default:
                continue
            }
        }
        return ""
    }
}
