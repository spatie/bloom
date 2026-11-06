import Foundation

/// What Select All, or a drag across several rows, puts on the pasteboard for a conversation.
///
/// The table only builds the rows near the reader, so the text cannot be read back out of the
/// views: it is composed from the stored rows, which are all there. Tool calls, thinking and
/// footers are left out because the transcript folds them away by default and nobody pastes a
/// session to read forty file reads.
public enum ConversationText {
    static let userLabel = "You"
    static let agentLabel = "Agent"

    /// A drag across rows: every row from `first` to `last` in full, except the two it started
    /// and ended in, where only the words under the drag are taken. Those two are given as text
    /// because they were read off screen while their rows were on it.
    public struct Slice: Equatable, Sendable {
        public var first: Int
        public var last: Int
        public var firstText: String
        public var lastText: String

        public init(first: Int, last: Int, firstText: String, lastText: String) {
            self.first = first
            self.last = last
            self.firstText = firstText
            self.lastText = lastText
        }
    }

    public static func text<Rows: Sequence>(
        of rows: Rows, in slice: Slice? = nil
    ) -> String where Rows.Element == TurnAnswer.Row {
        rows.compactMap { turn(of: $0, in: slice) }.joined(separator: "\n\n")
    }

    private static func turn(of row: TurnAnswer.Row, in slice: Slice?) -> String? {
        guard !row.isNested, let body = body(of: row) else { return nil }
        let wanted = selected(body, of: row.seq, in: slice)
        let trimmed = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(label(of: row.kind)):\n\(trimmed)"
    }

    private static func selected(_ body: String, of seq: Int, in slice: Slice?) -> String {
        guard let slice else { return body }
        if seq < slice.first || seq > slice.last { return "" }
        if seq == slice.first { return slice.firstText }
        if seq == slice.last { return slice.lastText }
        return body
    }

    private static func label(of kind: MessageKind) -> String {
        kind == .user ? userLabel : agentLabel
    }

    private static func body(of row: TurnAnswer.Row) -> String? {
        switch row.kind {
        case .user:
            return userBody(row.payload)
        case .assistantText:
            guard case .assistantText(let block)? = AgentEvent.decode(
                line: String(decoding: row.payload, as: UTF8.self)
            ) else { return nil }
            return block.text
        case .permissionAsk:
            guard case .permissionAsk(let ask)? = AgentEvent.decode(
                line: String(decoding: row.payload, as: UTF8.self)
            ), AgentQuestionnaire.isQuestion(toolName: ask.toolName) else { return nil }
            return AgentQuestionnaire.questions(in: ask.input).map(questionBody).joined(separator: "\n\n")
        default:
            return nil
        }
    }

    /// A question as the card shows it, without ticks: what was chosen lives in no stored row.
    private static func questionBody(_ question: AgentQuestion) -> String {
        let heading = [question.header.uppercased(), question.question].filter { !$0.isEmpty }
        let options = question.options.map { option in
            ["- \(option.label)", option.description.replacingOccurrences(of: "\n", with: "\n  ")]
                .filter { !$0.isEmpty }.joined(separator: "\n  ")
        }
        return (heading + options).joined(separator: "\n")
    }

    /// The words the bubble shows: a review turn's typed message, or the sentence without the
    /// attachment paths Bloom appended for the agent.
    private static func userBody(_ payload: Data) -> String {
        let typed = UserTurnPrompt.text(in: payload)
        return ReviewTurn.split(typed)?.message ?? AttachmentTrailer.split(typed).body
    }
}
