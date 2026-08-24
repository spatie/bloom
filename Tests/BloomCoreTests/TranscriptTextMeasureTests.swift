import Testing
import Foundation
@testable import BloomCore

@Suite("How a run of transcript prose says how big it is")
struct TranscriptTextMeasureTests {
    // MARK: What a run is laid out at

    /// The measurement that started this: at a container of 456, a wrapped paragraph's widest line
    /// is the ink in it and not the room it was given.
    @Test("a real proposal is what the run is laid out at")
    func finiteProposal() {
        #expect(TranscriptTextMeasure.layoutWidth(proposed: 456) == 456)
        #expect(TranscriptTextMeasure.layoutWidth(proposed: 1.5) == 1.5)
    }

    /// SwiftUI asks this of every run inside a `.textSelection(.enabled)` block, which is every
    /// paragraph of every answer. Declining it left a paragraph at one line of height with the
    /// rest cut off.
    @Test("no proposal at all is a question about the ideal size, and gets one")
    func unspecifiedProposal() {
        #expect(TranscriptTextMeasure.layoutWidth(proposed: nil) == TranscriptTextMeasure.idealWidth)
        #expect(TranscriptTextMeasure.layoutWidth(proposed: .infinity) == TranscriptTextMeasure.idealWidth)
        #expect(TranscriptTextMeasure.idealWidth.isFinite)
    }

    /// A container of zero lays out nothing at all, so the narrowest question has to be asked at a
    /// hair's width, where every line breaks at its widest unbreakable word.
    @Test("a proposal of nothing is asked at a hair's width rather than at zero")
    func zeroProposal() {
        #expect(TranscriptTextMeasure.layoutWidth(proposed: 0) == TranscriptTextMeasure.floorWidth)
        #expect(TranscriptTextMeasure.layoutWidth(proposed: -20) == TranscriptTextMeasure.floorWidth)
        #expect(TranscriptTextMeasure.floorWidth > 0)
    }

    // MARK: What it reports back

    @Test("a short run hugs its own words rather than the room it was offered")
    func hugsItsWords() {
        let size = TranscriptTextMeasure.size(
            widestLine: 52.4, usedHeight: 16, proposed: 456,
            laidOutAt: 456, lineHeight: 16, hasGlyphs: true
        )
        #expect(size == TranscriptTextMeasure.Size(width: 53, height: 16))
    }

    @Test("a run may not report itself wider than the room it was offered")
    func cappedByTheProposal() {
        let size = TranscriptTextMeasure.size(
            widestLine: 455.8, usedHeight: 64, proposed: 456,
            laidOutAt: 456, lineHeight: 16, hasGlyphs: true
        )
        #expect(size.width == 456)
        #expect(size.height == 64)
    }

    /// The ideal size is the run unwrapped, and it is allowed to be wider than any pane. Whatever
    /// asked the question caps it when it places the view.
    @Test("an ideal size is not capped, because nothing offered any room")
    func idealSizeIsNotCapped() {
        let size = TranscriptTextMeasure.size(
            widestLine: 2_400, usedHeight: 16, proposed: nil,
            laidOutAt: TranscriptTextMeasure.idealWidth, lineHeight: 16, hasGlyphs: true
        )
        #expect(size.width == 2_400)
    }

    @Test("an empty run takes no space, so an empty paragraph costs no line")
    func emptyRun() {
        let size = TranscriptTextMeasure.size(
            widestLine: 0, usedHeight: 0, proposed: 456,
            laidOutAt: 456, lineHeight: 16, hasGlyphs: false
        )
        #expect(size == TranscriptTextMeasure.Size(width: 0, height: 0))
    }

    // MARK: The floor, which is the one worth having

    /// Alex's bug written down. A numbered list drew "1." with the sentence beside it missing,
    /// which is what a row reporting no width looks like: the marker is drawn separately from the
    /// line, so it survives and the line does not.
    ///
    /// The cause was never found. This is the floor that makes the shape of it unreachable from
    /// here: a run holding words never reports a size a row could draw nothing in.
    @Test("a run holding words never reports a size that would draw nothing", arguments: [
        (0.0, 0.0),
        (0.0, 35.0),
        (589.0, 0.0),
        (-4.0, -4.0),
    ])
    func neverReportsNothing(widestLine: Double, usedHeight: Double) {
        let size = TranscriptTextMeasure.size(
            widestLine: widestLine, usedHeight: usedHeight, proposed: 592,
            laidOutAt: 592, lineHeight: 16, hasGlyphs: true
        )
        #expect(size.width > 0, "a run with words in it reported a width of \(size.width)")
        #expect(size.height > 0, "a run with words in it reported a height of \(size.height)")
    }

    /// The same floor with no proposal to fall back on, which is the case that has no obvious
    /// number in it and is exactly why `layoutWidth` answers with a finite one.
    @Test("the floor holds when nothing was proposed either")
    func theFloorHoldsWithoutAProposal() {
        let size = TranscriptTextMeasure.size(
            widestLine: 0, usedHeight: 0, proposed: nil,
            laidOutAt: TranscriptTextMeasure.layoutWidth(proposed: nil), lineHeight: 16, hasGlyphs: true
        )
        #expect(size.width > 0)
        #expect(size.height > 0)
    }
}
