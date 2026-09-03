import Foundation
import Testing
@testable import BloomCore

/// What may be drawn as one block of selectable text, pinned where the diff cannot be reached.
///
/// The happy run is the least interesting case here. What this rule exists to get right is where
/// a run STOPS: a hunk heading, either expander, a review comment band and the open comment
/// editor all draw a view between two lines, and text cannot flow through one. A break the rule
/// misses is a selection that jumps a band, and a break it invents is a selection that stops in
/// the middle of a hunk for no reason the reader can see.
struct DiffRunGroupingTests {
    /// Rows named by what they are, so a test reads like the list it describes.
    private enum Row {
        case line
        case other
    }

    private func chunks(_ rows: [Row], limit: Int = DiffRunGrouping.runLimit) -> [DiffRunGrouping.Chunk] {
        DiffRunGrouping.chunks(
            count: rows.count, isLine: { rows[$0] == .line }, limit: limit
        )
    }

    @Test func nothingGroupsIntoNothing() {
        #expect(chunks([]).isEmpty)
    }

    @Test func aStretchOfLinesIsOneRun() {
        #expect(chunks([.line, .line, .line, .line]) == [.run(0..<4)])
    }

    @Test func aLoneLineStaysASingleRatherThanARunOfOne() {
        #expect(chunks([.line]) == [.single(0)])
        #expect(chunks([.other, .line, .other]) == [.single(0), .single(1), .single(2)])
    }

    // MARK: - Where a run stops

    /// A comment band, an expander or a heading between two lines. The run has to end above it
    /// and start again below, which is the whole of what this type is for.
    @Test func aRowThatIsNotALineBreaksTheRun() {
        #expect(
            chunks([.line, .line, .other, .line, .line, .line])
                == [.run(0..<2), .single(2), .run(3..<6)]
        )
    }

    @Test func aBreakAtEitherEndLeavesTheRunWhole() {
        #expect(chunks([.other, .line, .line]) == [.single(0), .run(1..<3)])
        #expect(chunks([.line, .line, .other]) == [.run(0..<2), .single(2)])
    }

    /// Two bands under one line, which `appendAnnotations` produces whenever a line carries a
    /// comment and the editor is open on it.
    @Test func consecutiveBreaksEachStandAlone() {
        #expect(
            chunks([.line, .other, .other, .line, .line])
                == [.single(0), .single(1), .single(2), .run(3..<5)]
        )
    }

    /// The review pane's worst case: every line carries a band, so nothing may be grouped and
    /// every row goes back to the view that has always drawn it.
    @Test func aBandUnderEveryLineGroupsNothing() {
        let rows: [Row] = Array(repeating: [.line, .other], count: 5).flatMap(\.self)

        #expect(chunks(rows) == (0..<10).map { .single($0) })
    }

    // MARK: - The cap

    @Test func aRunLongerThanTheLimitIsSplitAtIt() {
        #expect(
            chunks(Array(repeating: .line, count: 900), limit: 400)
                == [.run(0..<400), .run(400..<800), .run(800..<900)]
        )
    }

    /// The remainder is one line, and one line is a single wherever it came from.
    @Test func aSplitLeavingOneLineLeavesASingle() {
        #expect(
            chunks(Array(repeating: .line, count: 401), limit: 400)
                == [.run(0..<400), .single(400)]
        )
    }

    @Test func aRunExactlyTheLimitIsNotSplit() {
        #expect(chunks(Array(repeating: .line, count: 400), limit: 400) == [.run(0..<400)])
    }

    /// A limit under two would make every run a single and turn the fix off without a word.
    @Test func anImpossibleLimitIsFlooredRatherThanObeyed() {
        #expect(chunks(Array(repeating: .line, count: 4), limit: 0) == [.run(0..<2), .run(2..<4)])
        #expect(chunks(Array(repeating: .line, count: 4), limit: 1) == [.run(0..<2), .run(2..<4)])
    }

    // MARK: - What the caller may rely on

    /// Every index appears exactly once and in order, because these chunks replace the row list
    /// rather than annotate it: a dropped index is a line that vanishes off the diff.
    @Test func theChunksCoverEveryRowExactlyOnceInOrder() {
        let rows: [Row] = [
            .other, .line, .line, .line, .other, .line, .other, .other, .line, .line,
        ]

        var covered: [Int] = []
        for chunk in chunks(rows) {
            switch chunk {
            case let .single(index): covered.append(index)
            case let .run(range): covered.append(contentsOf: range)
            }
        }

        #expect(covered == Array(rows.indices))
    }

    @Test func theChunksCoverEveryRowExactlyOnceUnderTheCapToo() {
        var covered: [Int] = []
        for chunk in chunks(Array(repeating: .line, count: 1_001), limit: 7) {
            switch chunk {
            case let .single(index): covered.append(index)
            case let .run(range): covered.append(contentsOf: range)
            }
        }

        #expect(covered == Array(0..<1_001))
    }
}
