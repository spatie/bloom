import Foundation

/// The head of a sent message too long to draw whole, revealed in stages.
///
/// A pasted API response or a base64 image is hundreds of kilobytes on one line, and laying it out
/// in a bubble froze the window on entering the chat, then for seconds each time the row scrolled
/// back into view. Each "Show more" reveals the next stage; the whole message is the last one.
/// Blocks Bloom appended are drawn as chips, so they are kept whole and cost nothing: cut, they
/// would no longer be recognised.
public enum SentTurnPreview {
    public struct Stage: Equatable, Sendable {
        public let lines: Int
        /// Counted in UTF-8 bytes, so the head is found without walking characters.
        public let bytes: Int

        public init(lines: Int, bytes: Int) {
            self.lines = lines
            self.bytes = bytes
        }
    }

    /// What the bubble opens on, then what "Show more" adds before the whole message.
    public static let stages = [Stage(lines: 100, bytes: 10_000), Stage(lines: 400, bytes: 30_000)]
    public static let ellipsis = "…"

    /// The head drawn at `stage`, or nil when the message fits in it or `stage` is past the last.
    public static func cut(_ text: String, stage: Int) -> String? {
        guard stages.indices.contains(stage) else { return nil }
        return cut(text, within: stages[stage])
    }

    /// The head of `text` within `limits`, with an ellipsis, or nil when it fits. Looks for
    /// Bloom's blocks only in a text already over the limits.
    public static func cut(_ text: String, within limits: Stage) -> String? {
        guard let end = limit(of: text, within: limits, skipping: []) else { return nil }
        let blocks = SentTurn.blockRanges(in: text)
        guard !blocks.isEmpty else { return String(text[..<end]) + ellipsis }
        return limit(of: text, within: limits, skipping: blocks).map { String(text[..<$0]) + ellipsis }
    }

    private static let newline = UInt8(ascii: "\n")

    /// Where the head stops, or nil when the text ends first. Reads at most `limits.bytes` bytes
    /// outside `blocks`, whatever the length of `text`.
    private static func limit(
        of text: String, within limits: Stage, skipping blocks: [Range<String.Index>]
    ) -> String.Index? {
        let utf8 = text.utf8
        var pending = blocks[...]
        var lines = 1
        var bytes = 0
        var index = utf8.startIndex
        while index < utf8.endIndex {
            if let block = pending.first, block.lowerBound <= index {
                index = max(index, block.upperBound)
                pending.removeFirst()
                continue
            }
            let isNewline = utf8[index] == newline
            let next = utf8.index(after: index)
            if bytes == limits.bytes || (isNewline && lines == limits.lines && next < utf8.endIndex) {
                return boundary(at: index, in: text)
            }
            if isNewline { lines += 1 }
            bytes += 1
            index = next
        }
        return nil
    }

    /// `index` moved back to the start of the character it falls in, so the head never ends inside
    /// one. A Windows line break is one character, so this also leaves its `\r` out of the head.
    private static func boundary(at index: String.Index, in text: String) -> String.Index {
        var index = index
        while index > text.startIndex, index.samePosition(in: text) == nil {
            index = text.utf8.index(before: index)
        }
        return index
    }
}
