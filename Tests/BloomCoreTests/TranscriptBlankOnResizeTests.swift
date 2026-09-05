import Testing
import Foundation
@testable import BloomCore

/// **Dragging the divider that resizes the composer left the whole transcript blank.**
///
/// Reported against `8fb409d3` with two screenshots three seconds apart: a full transcript, then
/// nothing at all between the pinned question strip and the composer. The pinned strip, the
/// composer, the sidebar and the inspector all survived, which is what says the rows were still
/// there and the table was the thing that went dark.
///
/// The divider moves the transcript's HEIGHT and never its width, so this suite pins the three
/// things a height change must not do, and then the two rules that stop it doing the fourth.
///
/// 1. It must not empty the height cache. `TranscriptRowHeights` has no notion of height at all,
///    and these tests are here so that nothing gives it one by handing a height to `reset` or
///    `rewidth`.
/// 2. It must not silence a row. A row measured at nothing is given no view by the table, and
///    nothing ever asks again, so a nought filed by a resize would be a conversation that stays
///    gone.
/// 3. It must not leave a hold on. A hold is armed by a width change and is what draws the pane's
///    own ground instead of the transcript.
/// 4. And it must not resolve a placement against a pane that has no height, which is what it was
///    doing. See `TranscriptAnchor.canPlace` for the whole of it: the end of the content measured
///    against a viewport of nought is the point BELOW the last row, and a reader put there sees
///    no rows, which leaves the table with nothing to anchor to, nothing to count and nothing to
///    repair. `PaneMeasure` is where the pane of no height came from.
@Suite("The transcript going blank when the composer is resized")
struct TranscriptBlankOnResizeTests {
    /// A key from one string, which is all these tests need to tell two entries apart. The real
    /// one combines a dozen fields: see `TranscriptContentKey`.
    private func key(_ text: String) -> TranscriptContentKey {
        TranscriptContentKey { $0.combine(text) }
    }

    // MARK: - A pane of no height is not a place to put anybody

    /// The arithmetic the guard exists for, written down so nobody has to rediscover it. With no
    /// viewport there is no last screen, so the end of the content is the whole of it, and that
    /// point is past every row rather than at the last of them.
    @Test("the end of a pane with no height is below the last row")
    func endOfAPaneWithNoHeightIsPastTheContent() {
        #expect(TranscriptAnchor.end(contentHeight: 30_000, viewportHeight: 0) == 30_000)
        #expect(
            TranscriptAnchor.clamped(30_000, contentHeight: 30_000, viewportHeight: 0) == 30_000
        )
    }

    @Test("nothing is placed against a pane that has not been laid out")
    func refusesAPaneWithNoHeight() {
        #expect(!TranscriptAnchor.canPlace(viewportHeight: 0))
        #expect(!TranscriptAnchor.canPlace(viewportHeight: 1))
        #expect(!TranscriptAnchor.canPlace(viewportHeight: -40))
    }

    /// A transcript squeezed to its floor is still a transcript, and a reader in one still has to
    /// be put back where they were.
    @Test("a pane dragged down to its floor is still placed")
    func placesARealPane() {
        #expect(TranscriptAnchor.canPlace(viewportHeight: 120))
        #expect(TranscriptAnchor.canPlace(viewportHeight: 900))
    }

    // MARK: - Where a pane of no height came from

    /// The composer publishes its chrome as the difference between its own height and the editor's,
    /// and a drag moves the editor a frame before the composer is measured at it, so that
    /// difference comes out negative on any frame the hand outruns the layout.
    @Test("a pass that cannot measure the chrome keeps the last one")
    func keepsAKnownChrome() {
        #expect(PaneMeasure.chrome(-30, knowing: 72) == 72)
        #expect(PaneMeasure.chrome(0, knowing: 72) == 72)
        // A real measurement still wins, and still rounds up.
        #expect(PaneMeasure.chrome(90, knowing: 72) == 96)
    }

    /// Nought until there is anything to know, which is what a composer that has never been laid
    /// out starts from.
    @Test("a composer with nothing known yet still reports nothing")
    func keepsNothingWhenNothingIsKnown() {
        #expect(PaneMeasure.chrome(-30, knowing: 0) == 0)
    }

    /// **This is the bug, as arithmetic.** The floor is subtracted from the room along with the
    /// chrome, so a chrome reported as nought hands the editor the chrome as well, and a composer
    /// carrying chips has more chrome than the floor is wide. The transcript is then given a
    /// height of nothing rather than of 120.
    @Test("a chrome of nought lets the composer take the whole transcript")
    func aChromeOfNoughtTakesTheFloor() {
        let room: CGFloat = 800
        let realChrome: CGFloat = 136
        let floor: CGFloat = 120
        let line: CGFloat = 20

        let honest = PaneMeasure.editorCap(
            room: room, chrome: realChrome, floor: floor, atLeast: line
        )
        #expect(room - (honest + realChrome) == floor)

        let lost = PaneMeasure.editorCap(room: room, chrome: 0, floor: floor, atLeast: line)
        #expect(room - (lost + realChrome) < 0)
    }

    /// A pane nobody has laid out is no cap at all, which is nought's meaning everywhere else in
    /// `PaneMeasure`. It must not come out as a floor subtracted from nothing.
    @Test("a pane with no room caps nothing")
    func noRoomIsNoCap() {
        #expect(
            PaneMeasure.editorCap(room: 0, chrome: 72, floor: 120, atLeast: 20)
                == .greatestFiniteMagnitude
        )
    }

    /// The editor keeps a line whatever the arithmetic says, so a very short pane leaves a box
    /// somebody can still type in rather than a hairline.
    @Test("the editor keeps a line in a pane with no room to spare")
    func keepsALine() {
        #expect(PaneMeasure.editorCap(room: 130, chrome: 72, floor: 120, atLeast: 20) == 20)
    }

    // MARK: - A height change empties no heights

    /// `reset` takes a width, a text size and a line height, and a pane's height is none of those.
    /// Said twice with the same three, it must answer that nothing moved and keep every number.
    @Test("a resize that changes only the height keeps every measured row")
    func heightIsNotPartOfTheCache() {
        var heights = TranscriptRowHeights()
        let first = heights.reset(width: 900, scale: 1, leading: 1.7)
        #expect(first)
        heights.note(240, for: key("row.7"), shape: .answer, measuredAt: 900)
        heights.note(22, for: key("row.8"), shape: .fold, measuredAt: 900)

        // The pane is half as tall as it was. Nothing above changed, so nothing here may.
        let again = heights.reset(width: 900, scale: 1, leading: 1.7)
        #expect(!again)
        #expect(heights.height(for: key("row.7")) == 240)
        #expect(heights.height(for: key("row.8")) == 22)
        #expect(heights.count == 2)
    }

    /// `rewidth` is the resize path, and it is the WIDTH path. A pane that is the same width owes
    /// no measurement, however tall it has become.
    @Test("a pane that is the same width owes no remeasurement")
    func rewidthIsAWidthQuestion() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 900, scale: 1, leading: 1.7)
        heights.note(240, for: key("row.7"), shape: .answer, measuredAt: 900)

        let moved = heights.rewidth(to: 900)
        #expect(!moved)
        #expect(heights.staleCount == 0)
        #expect(heights.height(for: key("row.7")) == 240)
    }

    /// And a cache that has been told a width stays ready for ever, so a table can never be
    /// answered a hair per row after it has once been answered properly. A transcript told a
    /// hundredth of a point per row is a transcript that is not there.
    @Test("a cache that has a width never stops having one")
    func staysReady() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 900, scale: 1, leading: 1.7)
        heights.note(240, for: key("row.7"), shape: .answer, measuredAt: 900)
        heights.forget()
        #expect(heights.isReady)
        let refused = heights.reset(width: 0.5, scale: 1, leading: 1.7)
        #expect(!refused)
        #expect(heights.isReady)
    }

    // MARK: - A height change silences no row

    /// A row is silenced by being measured at nothing: the table builds no view for one, so
    /// nothing can ever report a better number. A resize must leave every measured row saying
    /// exactly what it said.
    @Test("a resize silences no row that draws something")
    func silencesNothing() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 900, scale: 1, leading: 1.7)
        heights.note(240, for: key("row.7"), shape: .answer, measuredAt: 900)
        heights.note(0, for: key("row.8"), shape: .notice, measuredAt: 900)

        let same = heights.reset(width: 900, scale: 1, leading: 1.7)
        #expect(!same)
        #expect(!heights.measuredNothing(key("row.7")))
        // The row that really does draw nothing is still allowed to say so.
        #expect(heights.measuredNothing(key("row.8")))
    }

    /// The promise at the head of `TranscriptRowHeights`: a row nobody has measured is told an
    /// estimate, never nothing. Only a row that has SAID it draws nothing, or one claimed to by
    /// `TranscriptRowInk`, is answered nought.
    @Test("an unmeasured row is estimated rather than answered nothing")
    func unmeasuredRowsAreNeverNought() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 900, scale: 1, leading: 1.7)
        heights.showing(SessionID("one"))
        for shape in TranscriptRowShape.allCases {
            #expect(heights.assumed(for: key("unseen.\(shape)"), shape: shape) > 0)
        }
        #expect(heights.assumed(for: key("unseen"), shape: .answer) > 0)
    }

    /// `TranscriptRowInk` is what a row will draw, and it is answered from the row itself. Nothing
    /// about a pane reaches it, so a resize cannot make a row claim to be empty.
    @Test("what a row draws is a question about the row, not about the pane")
    func inkIsAboutTheRow() {
        let ordinary = Data(#"{"type":"assistant","subtype":"text"}"#.utf8)
        #expect(!TranscriptRowInk.drawsNothing(kind: .assistantText, payload: ordinary))
        let start = Data(#"{"type":"system","subtype":"init"}"#.utf8)
        #expect(!TranscriptRowInk.drawsNothing(kind: .system, payload: start))
        let noise = Data(#"{"type":"system","subtype":"compact_boundary"}"#.utf8)
        #expect(TranscriptRowInk.drawsNothing(kind: .system, payload: noise))
    }

    // MARK: - A height change leaves no hold on

    /// A hold draws the pane's own ground in place of the transcript, so a height change taking
    /// one would be this bug by another route. `holds` is asked about two widths and nothing else.
    @Test("a pane that changed only its height is not held")
    func aHeightChangeIsNotAHold() {
        #expect(!TranscriptPaneHold.holds(from: 900, to: 900))
        #expect(!TranscriptPaneHold.holds(from: 900, to: 900.25))
    }

    /// And every hold that is taken lets go by itself, so no gesture whose end goes missing can
    /// leave a pane blank for the rest of the session.
    @Test("every hold has a deadline")
    func everyHoldLetsGo() {
        for held in [TranscriptPaneHold.PaneHeld.whatIsDrawn, .nothing] {
            for hand in [true, false] {
                #expect(TranscriptPaneHold.letsGo(of: held, underAHand: hand) > .zero)
                #expect(TranscriptPaneHold.letsGo(of: held, underAHand: hand) < .seconds(5))
            }
        }
    }
}
