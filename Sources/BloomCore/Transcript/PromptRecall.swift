import Foundation

/// Up and Down in the composer walking through what was already sent in this conversation, the
/// way a shell walks its history.
///
/// **It only starts in an empty composer.** An arrow key in a draft somebody is writing moves the
/// caret, and taking that away to replace their words with an old prompt would be the worst thing
/// the key could do. Once a prompt has been recalled the arrows keep walking, but only while the
/// composer still holds exactly what was recalled: an edit makes it the owner's draft, and the
/// arrows go back to being arrows.
///
/// **And only from the edge line.** A recalled prompt can run to several lines, and Up in the
/// middle of one is somebody moving through it. Up walks back from the first line, Down walks
/// forward from the last, which is also how a shell treats a multi-line command.
///
/// There is no stored history. The prompts are read from the conversation's own user rows on
/// every key press, so a turn sent from another pane, or a conversation reopened tomorrow, is
/// already in it, and there is nothing to persist or to fall out of step.
public struct PromptRecall: Equatable, Sendable {
    public enum Direction: Sendable {
        case older
        case newer
    }

    /// Which prompt is in the composer, as an index into the list the last step was taken over.
    public private(set) var position: Int?
    /// The text the last step put in the composer, which is how an edit is noticed.
    public private(set) var recalled: String?

    public init() {}

    public var isBrowsing: Bool { position != nil }

    /// One press of an arrow key.
    ///
    /// - Parameters:
    ///   - prompts: what was sent, oldest first. See `prompts(from:)`.
    ///   - draft: what the composer holds now, without any leading `/command`.
    ///   - caret: where the caret is in `draft`, in UTF-16 units, which is what the text view counts.
    /// - Returns: the text to put in the composer, or nil when the key is not recall's and should
    ///   move the caret as usual.
    public mutating func step(
        _ direction: Direction, prompts: [String], draft: String, caret: Int
    ) -> String? {
        if let recalled, draft != recalled { reset() }

        switch direction {
        case .older:
            if let position {
                guard Self.isOnFirstLine(draft, caret: caret) else { return nil }
                // At the oldest prompt the key is still recall's. Letting it through would move
                // the caret to the start of a single line, which reads as the list having ended
                // somewhere odd rather than at the beginning.
                return land(on: max(min(position, prompts.count) - 1, 0), in: prompts)
            }
            guard draft.isEmpty, !prompts.isEmpty else { return nil }
            return land(on: prompts.count - 1, in: prompts)

        case .newer:
            guard let position, Self.isOnLastLine(draft, caret: caret) else { return nil }
            guard position + 1 < prompts.count else {
                // Past the newest prompt is the empty composer the walk started from.
                reset()
                return ""
            }
            return land(on: position + 1, in: prompts)
        }
    }

    public mutating func reset() {
        position = nil
        recalled = nil
    }

    private mutating func land(on index: Int, in prompts: [String]) -> String? {
        guard prompts.indices.contains(index) else {
            reset()
            return nil
        }
        position = index
        recalled = prompts[index]
        return prompts[index]
    }

    /// What a person typed in each sent turn, oldest first, ready to be put back in a composer.
    ///
    /// The same peeling `UserTurnPrompt.summary` does, without collapsing the whitespace or capping
    /// the length, because this goes back into an editor rather than onto one line. Instructions
    /// Bloom injected come off, and so does a review's scaffolding: the comments were chips that
    /// have since been sent and deleted, and recalling the template that carried them would hand
    /// back several paragraphs nobody wrote. A turn that was nothing but those is skipped. The
    /// same prompt sent twice in a row is one step, as it is in a shell.
    public static func prompts(from sent: [String]) -> [String] {
        var output: [String] = []
        for text in sent {
            let presented = SentTurn.withoutInstructions(text)
            let typed = ReviewTurn.split(presented)?.message ?? presented
            let prompt = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty, output.last != prompt else { continue }
            output.append(prompt)
        }
        return output
    }

    static func isOnFirstLine(_ text: String, caret: Int) -> Bool {
        let utf16 = text.utf16
        let end = utf16.index(utf16.startIndex, offsetBy: min(max(caret, 0), utf16.count))
        return !utf16[..<end].contains(newline)
    }

    static func isOnLastLine(_ text: String, caret: Int) -> Bool {
        let utf16 = text.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: min(max(caret, 0), utf16.count))
        return !utf16[start...].contains(newline)
    }

    private static let newline = UInt16(UInt8(ascii: "\n"))
}
