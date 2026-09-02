import Testing
import Foundation
@testable import BloomCore

@Suite("The gap a markdown list puts between its items")
struct ListLeadingTests {
    /// The five steps of `ChatTextSize` resolved against the body rung on macOS 26: the point size
    /// San Francisco comes out at, and the line box `NSLayoutManager` lays it out in. The same
    /// table `ChatLineHeightTests` and `TextLeadingTests` measured, and measured rather than
    /// derived for their reason: nothing in the core can ask AppKit for the answer.
    private static let bodySteps: [(size: Double, box: Double)] = [
        (12, 15), (13, 16), (15, 18), (17, 20), (20, 23),
    ]

    private static func gaps(tight: Bool, size: Double, box: Double) -> [Double] {
        ChatLineHeight.allCases.map {
            ListLeading.betweenItems(
                tight: tight, lineHeight: box, pointSize: size, ratio: $0.listRatio
            )
        }
    }

    /// **The reader who has never opened the setting has to see the list they saw yesterday.** Six
    /// points between the items of a loose list is `Metrics.spacingTight`'s neighbour on the
    /// window's spacing scale, `Metrics.spacing`, which is the literal the view was hard coding
    /// before any of this. Landing back on it at the default step is what makes this a fix rather
    /// than a redesign, and it is the one number here that may not drift.
    @Test("the default step lands back on the six points the view used to hard code")
    func theDefaultDoesNotMove() {
        let loose = ListLeading.betweenItems(
            tight: false, lineHeight: 16, pointSize: 13, ratio: ChatLineHeight.standard.listRatio
        )
        #expect(loose == 6)
    }

    /// **The whole of whether the setting reaches a list at all**, and it is asked as a comparison
    /// rather than as a ladder of its own. The gap is the leading an item's own lines are given,
    /// so it moves exactly where that leading moves and rounds to the same point where it does
    /// not: at the smallest chat text size, `listRatio` puts the middle two steps within a point
    /// of each other and both land on two, which is `ChatLineHeight.listRatio`'s rounding and is
    /// already what the lines inside an item do there. Asserting the two agree catches a gap that
    /// has stopped following the setting, and does not fail for a collapse it did not cause.
    @Test("the gap moves with the step wherever an item's own lines do")
    func theLineHeightReachesTheGaps() {
        for step in Self.bodySteps {
            let leadings = ChatLineHeight.allCases.map {
                TextLeading.overPointSize(
                    lineHeight: step.box, pointSize: step.size, ratio: $0.listRatio
                )
            }
            for tight in [true, false] {
                let points = Self.gaps(tight: tight, size: step.size, box: step.box)
                for index in points.indices.dropFirst() {
                    let gapOpened = points[index] > points[index - 1]
                    let lineOpened = leadings[index] > leadings[index - 1]
                    #expect(gapOpened == lineOpened)
                    #expect(points[index] >= points[index - 1])
                }
            }
        }
    }

    /// And it does something at every size: whatever a single step rounds to, the loosest setting
    /// is further apart than the tightest one wherever the reader has put the text size.
    @Test("the ends of the control are apart at every text size")
    func theControlHasARangeEverywhere() {
        for step in Self.bodySteps {
            for tight in [true, false] {
                let points = Self.gaps(tight: tight, size: step.size, box: step.box)
                #expect(points.last! > points.first!)
            }
        }
    }

    @Test("the default text size answers one point a step tight, and two loose")
    func theDefaultSizeIsAnEvenLadder() {
        #expect(Self.gaps(tight: true, size: 13, box: 16) == [1, 2, 3, 4, 5])
        #expect(Self.gaps(tight: false, size: 13, box: 16) == [2, 4, 6, 8, 10])
    }

    /// The distinction markdown itself draws, held at every step and every size. A list written
    /// with blank lines between its items has to stay looser than one written without them,
    /// whatever the reader has set.
    @Test("a tight list stays tighter than a loose one, everywhere")
    func tightStaysTighterThanLoose() {
        for step in Self.bodySteps {
            for lineHeight in ChatLineHeight.allCases {
                let tight = ListLeading.betweenItems(
                    tight: true, lineHeight: step.box, pointSize: step.size,
                    ratio: lineHeight.listRatio
                )
                let loose = ListLeading.betweenItems(
                    tight: false, lineHeight: step.box, pointSize: step.size,
                    ratio: lineHeight.listRatio
                )
                #expect(tight < loose)
            }
        }
    }

    /// **The bug, written down.** The gaps used to be `Metrics.spacingTight` at two points, while
    /// the wrapped lines inside a single item were led by three at the default step: an item's own
    /// lines belonged to each other less than the items did, which is what made a bulleted answer
    /// look broken. An item is now never closer to its neighbour than its own lines are to each
    /// other, at any step and any size.
    @Test("an item is never closer to the next item than to its own next line")
    func itemsAreNeverTighterThanTheirOwnLines() {
        for step in Self.bodySteps {
            for lineHeight in ChatLineHeight.allCases {
                let withinAnItem = TextLeading.overPointSize(
                    lineHeight: step.box, pointSize: step.size, ratio: lineHeight.listRatio
                )
                let betweenItems = ListLeading.betweenItems(
                    tight: true, lineHeight: step.box, pointSize: step.size,
                    ratio: lineHeight.listRatio
                )
                #expect(betweenItems >= withinAnItem)
            }
        }
    }

    /// A larger conversation opens its lists up as well, which fixed points never did: two points
    /// between the items of a list set at twenty was a third of what the same list got at twelve.
    @Test("a larger text size opens the gaps too")
    func theTextSizeReachesTheGapsAsWell() {
        for lineHeight in ChatLineHeight.allCases {
            let bySize = Self.bodySteps.map {
                ListLeading.betweenItems(
                    tight: false, lineHeight: $0.box, pointSize: $0.size, ratio: lineHeight.listRatio
                )
            }
            #expect(bySize.first! < bySize.last!)
        }
    }

    /// `TextLeading.overPointSize` answers nothing for a font it cannot measure, and a gap has to
    /// do the same rather than double it into something.
    @Test("a font with no size at all gets no gap")
    func nothingToMeasureIsNoGap() {
        #expect(ListLeading.betweenItems(tight: false, lineHeight: 0, pointSize: 13, ratio: 1.45) == 0)
        #expect(ListLeading.betweenItems(tight: true, lineHeight: 16, pointSize: 0, ratio: 1.45) == 0)
    }
}
