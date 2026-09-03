import Foundation

/// The words a person typed, recovered from a stored user row.
///
/// Both agent backends persist the same user-message envelope. Keeping the extraction here stops
/// the full bubble, transcript navigation and any future summary from each growing its own parser.
public enum UserTurnPrompt {
    /// Enough text to identify a question in a one-line navigation control without retaining a
    /// multi-page prompt in that control. The view still applies line truncation for narrow panes.
    public static let summaryLimit = 180

    public static func text(in payload: Data) -> String {
        guard let blocks = JSONValue.parse(payload)?["message"]?["content"]?.arrayValue else {
            return ""
        }
        return blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    /// A compact account of the visible user bubble, without attachment trailers or review
    /// scaffolding that the bubble itself also removes.
    public static func summary(in payload: Data, limit: Int = summaryLimit) -> String? {
        summary(of: text(in: payload), limit: limit)
    }

    public static func summary(of text: String, limit: Int = summaryLimit) -> String? {
        let presented = SentTurn.withoutInstructions(text)
        let visible: String
        if let review = ReviewTurn.split(presented) {
            visible = if review.message.isEmpty {
                Counted.of(review.chips.count, "review comment")
            } else {
                review.message
            }
        } else {
            let turn = AttachmentTrailer.split(presented)
            if !turn.body.isEmpty {
                visible = turn.body
            } else if turn.paths.count == 1, let path = turn.paths.first {
                visible = "Attached \(URL(fileURLWithPath: path).lastPathComponent)"
            } else if !turn.paths.isEmpty {
                visible = "\(turn.paths.count) attachments"
            } else {
                visible = presented
            }
        }

        let oneLine = visible.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        let cap = max(1, limit)
        guard oneLine.count > cap else { return oneLine }
        return String(oneLine.prefix(cap)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
