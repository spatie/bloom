import Foundation

/// A drag can cross independently laid out markdown blocks in either direction. Offsets use
/// UTF-16 because AppKit selections do, including when the answer contains emoji.
public enum TranscriptSelection {
    public struct Position: Comparable, Sendable {
        public var block: Int
        public var offset: Int

        public init(block: Int, offset: Int) {
            self.block = block
            self.offset = offset
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.block == rhs.block ? lhs.offset < rhs.offset : lhs.block < rhs.block
        }
    }

    public static func ranges(lengths: [Int], anchor: Position, end: Position) -> [NSRange] {
        let lower = min(anchor, end)
        let upper = max(anchor, end)
        return lengths.enumerated().map { block, length in
            guard block >= lower.block, block <= upper.block else {
                return NSRange(location: 0, length: 0)
            }
            let start = block == lower.block ? min(max(lower.offset, 0), length) : 0
            let finish = block == upper.block ? min(max(upper.offset, 0), length) : length
            return NSRange(location: start, length: max(0, finish - start))
        }
    }
}
