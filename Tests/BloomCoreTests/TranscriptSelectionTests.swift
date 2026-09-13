import Foundation
import Testing
@testable import BloomCore

struct TranscriptSelectionTests {
    @Test func crossesBlocksInEitherDirection() {
        let start = TranscriptSelection.Position(block: 0, offset: 3)
        let end = TranscriptSelection.Position(block: 2, offset: 4)
        let expected = [NSRange(location: 3, length: 7), NSRange(location: 0, length: 20),
                        NSRange(location: 0, length: 4), NSRange(location: 0, length: 0)]
        #expect(TranscriptSelection.ranges(lengths: [10, 20, 8, 5], anchor: start, end: end) == expected)
        #expect(TranscriptSelection.ranges(lengths: [10, 20, 8, 5], anchor: end, end: start) == expected)
    }

    @Test func unicodeUsesNativeOffsets() {
        let text = "Hello 🌱 café" as NSString
        let range = text.range(of: "🌱 café")
        let selected = TranscriptSelection.ranges(
            lengths: [text.length], anchor: .init(block: 0, offset: range.location),
            end: .init(block: 0, offset: text.length)
        )
        #expect(selected == [range])
        #expect(text.substring(with: selected[0]) == "🌱 café")
    }

    @Test func shrinkingTextClampsSelection() {
        let selected = TranscriptSelection.ranges(
            lengths: [3, 0, 2], anchor: .init(block: 0, offset: 8), end: .init(block: 2, offset: 9)
        )
        #expect(selected == [NSRange(location: 3, length: 0), NSRange(location: 0, length: 0),
                             NSRange(location: 0, length: 2)])
    }
}
