import Foundation

/// Where a long answer is cut into rows of the transcript table.
///
/// A row is built whole as soon as any of it is on screen, so an answer of 1,300 points cost a
/// 100 ms frame each time a fast wheel brought one in, and a 140 kB one held the main thread for
/// seconds. Cut only where a top-level block starts, so each part parses to the blocks it drew
/// inside the whole answer.
public enum TranscriptAnswerParts {
    /// Shorter answers stay one row. 92 per cent of a real database's answers were under 3 kB.
    public static let threshold = 4_000
    /// Characters per part: about a third of a screen of prose.
    public static let target = 1_500

    /// The answer's parts, in order. One part, the text itself, when it is not worth cutting.
    public static func split(_ text: String) -> [String] {
        guard text.utf8.count > threshold else { return [text] }
        let (lines, blocks) = MarkdownParser.topLevelBlocks(of: text)
        let starts = cuts(sizes: blocks.map { size(of: lines[$0]) }).map { blocks[$0].lowerBound }
        guard starts.count > 1 else { return [text] }
        return starts.indices.map { index in
            var part = lines[starts[index]..<(index + 1 < starts.count ? starts[index + 1] : lines.count)]
            // Only the blank lines between blocks go: a part opening on indented code keeps its indent.
            while let last = part.last, last.trimmingCharacters(in: .whitespaces).isEmpty { part.removeLast() }
            return part.joined(separator: "\n")
        }
    }

    /// The indices of the blocks that open a part. A part closes once it reaches `target`, unless
    /// what would be left after it is less than half a part, which then stays with it.
    static func cuts(sizes: [Int]) -> [Int] {
        guard !sizes.isEmpty else { return [] }
        var remaining = sizes.reduce(0, +)
        var opening = [0]
        var current = 0
        for (index, size) in sizes.enumerated() {
            if current >= target, remaining >= target / 2 {
                opening.append(index)
                current = 0
            }
            current += size
            remaining -= size
        }
        return opening
    }

    private static func size(of lines: ArraySlice<String>) -> Int {
        lines.reduce(0) { $0 + $1.utf8.count + 1 }
    }
}
