import Testing
import Foundation
@testable import BloomCore

@Suite("The steps the conversation's line height is set in")
struct ChatLineHeightTests {
    /// The five steps of `ChatTextSize` resolved against the body rung on macOS 26: the point size
    /// San Francisco comes out at, and the line box `NSLayoutManager` lays it out in. The same
    /// table `TextLeadingTests` measured, and measured rather than derived for the same reason:
    /// the rounding to a whole point happens twice on the way here and nothing in the core can ask
    /// AppKit for the answer.
    private static let bodySteps: [(size: Double, box: Double)] = [
        (12, 15), (13, 16), (15, 18), (17, 20), (20, 23),
    ]

    @Test("the middle step is what the transcript was already set at")
    func theDefaultIsWhereItWas() {
        #expect(ChatLineHeight.standard.ratio == 1.7)
        #expect(TextLeading.proseRatio == ChatLineHeight.standard.ratio)
        #expect(ChatLineHeight.allCases.count == 5)
        #expect(ChatLineHeight.allCases[2] == .standard)
    }

    /// **The whole of whether this is a control or a decoration.** `TextLeading.overPointSize`
    /// rounds to a whole point, so two steps that answer the same number of points are one step
    /// wearing two labels. Asked at every chat text size, because a pair that separates at the
    /// largest one can still collapse at the smallest.
    @Test("every step is a different number of points from its neighbour, at every text size")
    func neighboursAreVisiblyApart() {
        for step in Self.bodySteps {
            let points = ChatLineHeight.allCases.map {
                TextLeading.overPointSize(
                    lineHeight: step.box, pointSize: step.size, ratio: $0.ratio
                )
            }
            for (tighter, looser) in zip(points, points.dropFirst()) {
                #expect(looser > tighter)
            }
        }
    }

    @Test("the default text size answers two points a step, from two to ten")
    func theDefaultSizeIsAnEvenLadder() {
        let points = ChatLineHeight.allCases.map {
            TextLeading.overPointSize(lineHeight: 16, pointSize: 13, ratio: $0.ratio)
        }
        #expect(points == [2, 4, 6, 8, 10])
    }

    /// The range the request asked to cover, held at both ends. Tighter than 1.4 stops being a
    /// preference and starts being a paragraph that is hard to read; looser than 2.0 and the lines
    /// stop reading as one block of text.
    @Test("the range runs from dense to airy and stops there")
    func theEndsAreWhereTheyWereChosen() {
        #expect(ChatLineHeight.allCases.first?.ratio == 1.4)
        #expect(ChatLineHeight.allCases.last?.ratio == 2)
    }

    @Test("the steps are ordered, evenly, tightest first")
    func theLadderIsEven() {
        let ratios = ChatLineHeight.allCases.map(\.ratio)
        let gaps = zip(ratios, ratios.dropFirst()).map { $1 - $0 }
        for gap in gaps {
            #expect(abs(gap - 0.15) < 0.0001)
        }
    }

    /// Every step reaches the same slot the picker binds to, under a raw value that is written to
    /// `UserDefaults` and read back on the next launch. A renamed case is a reader whose setting
    /// silently goes home to the default.
    @Test("a step survives the round trip through its raw value")
    func rawValuesRoundTrip() {
        for step in ChatLineHeight.allCases {
            #expect(ChatLineHeight(rawValue: step.rawValue) == step)
        }
        #expect(ChatLineHeight.defaultsKey == "chat.lineHeight")
    }

    @Test("every step has a name of its own")
    func titlesAreDistinct() {
        let titles = ChatLineHeight.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(ChatLineHeight.standard.title == "Default")
    }

    /// The code block is a separate decision against a separate denominator, and this setting
    /// deliberately leaves it alone: see `TextLeading.codeRatio`. Folding the two together would
    /// set a wrapped shell command at 2.0 of its own line box at the loosest step, and at 1.4 of
    /// it at the tightest, which is the reverse of the reason code is led at all.
    @Test("the code ratio is not on this ladder")
    func codeIsNotMoved() {
        #expect(!ChatLineHeight.allCases.map(\.ratio).contains(TextLeading.codeRatio))
        #expect(TextLeading.overLineBox(lineHeight: 13) == 4)
    }
}
