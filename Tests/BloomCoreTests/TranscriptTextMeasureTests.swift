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
            widestLine: 52.4, usedHeight: 16, proposed: 456, lineHeight: 16, hasGlyphs: true
        )
        #expect(size == TranscriptTextMeasure.Size(width: 53, height: 16))
    }

    @Test("a run may not report itself wider than the room it was offered")
    func cappedByTheProposal() {
        let size = TranscriptTextMeasure.size(
            widestLine: 455.8, usedHeight: 64, proposed: 456, lineHeight: 16, hasGlyphs: true
        )
        #expect(size.width == 456)
        #expect(size.height == 64)
    }

    /// The ideal size is the run unwrapped, and it is allowed to be wider than any pane. Whatever
    /// asked the question caps it when it places the view.
    @Test("an ideal size is not capped, because nothing offered any room")
    func idealSizeIsNotCapped() {
        let size = TranscriptTextMeasure.size(
            widestLine: 2_400, usedHeight: 16, proposed: nil, lineHeight: 16, hasGlyphs: true
        )
        #expect(size.width == 2_400)
    }

    @Test("an empty run takes no space, so an empty paragraph costs no line")
    func emptyRun() {
        let size = TranscriptTextMeasure.size(
            widestLine: 0, usedHeight: 0, proposed: 456, lineHeight: 16, hasGlyphs: false
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
            widestLine: widestLine, usedHeight: usedHeight,
            proposed: 592, lineHeight: 16, hasGlyphs: true
        )
        #expect(size.width > 0, "a run with words in it reported a width of \(size.width)")
        #expect(size.height > 0, "a run with words in it reported a height of \(size.height)")
    }

    /// The same floor with no proposal to fall back on, which is the case that has no obvious
    /// number in it.
    @Test("the floor holds when nothing was proposed either")
    func theFloorHoldsWithoutAProposal() {
        let size = TranscriptTextMeasure.size(
            widestLine: 0, usedHeight: 0, proposed: nil, lineHeight: 16, hasGlyphs: true
        )
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    // MARK: And the floor never answers with the scratch width

    /// A paragraph of nothing but line breaks, asked what its ideal size is.
    ///
    /// This is not a contrived string and the numbers are not invented: measured on the same
    /// TextKit 1 stack `TranscriptTextView` builds, "\n" lays out two real line fragments, both of
    /// them zero points wide, so the widest line is zero while the run plainly has glyphs. The
    /// floor caught it and answered with the width it had just been laid out at, which for a
    /// question about the ideal size is `idealWidth`. The run reported itself a hundred thousand
    /// points wide, which is not a smaller failure than the blank row the floor exists to prevent.
    @Test("a run that drew no ink reports a hair's width, not the scratch measure it was laid out in")
    func inkFreeRunDoesNotReportTheScratchWidth() {
        let size = TranscriptTextMeasure.size(
            widestLine: 0, usedHeight: 32, proposed: nil, lineHeight: 16, hasGlyphs: true
        )
        #expect(size.width == TranscriptTextMeasure.floorWidth)
        #expect(size.height == 32)
    }

    /// The same run with room offered, which is every placement the layout system ever makes. It
    /// may have that room and not a point more.
    @Test("a run that drew no ink falls back to the room it was offered")
    func inkFreeRunFallsBackToTheProposal() {
        let size = TranscriptTextMeasure.size(
            widestLine: 0, usedHeight: 32, proposed: 456, lineHeight: 16, hasGlyphs: true
        )
        #expect(size.width == 456)
    }

    /// The rule the two above are cases of, swept over every proposal this view is asked about and
    /// every degenerate measurement it could come back with.
    ///
    /// `idealWidth` is a container to lay out in, not a size to be drawn at. Nothing here may
    /// report a width no proposal named and no glyph occupied.
    @Test("no answer is ever the scratch width unless the ink really is that wide")
    func neverAnswersWithTheScratchWidth() {
        let proposals: [Double?] = [nil, .infinity, 0, -20, 1, 456, 592]
        for proposed in proposals {
            for widestLine in [0.0, -4.0, 12.0] {
                for usedHeight in [0.0, 35.0] {
                    let size = TranscriptTextMeasure.size(
                        widestLine: widestLine, usedHeight: usedHeight,
                        proposed: proposed, lineHeight: 16, hasGlyphs: true
                    )
                    let place = "widest line \(widestLine), height \(usedHeight), "
                        + "proposal \(String(describing: proposed))"
                    #expect(size.width > 0, "\(place) reported a width of \(size.width)")
                    #expect(size.height > 0, "\(place) reported a height of \(size.height)")
                    #expect(
                        size.width < TranscriptTextMeasure.idealWidth,
                        "\(place) reported a width of \(size.width)"
                    )
                }
            }
        }
    }
}
