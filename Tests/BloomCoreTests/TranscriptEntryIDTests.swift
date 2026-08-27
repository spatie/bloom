import Testing
import Foundation
@testable import BloomCore

@Suite("What a transcript entry's id promises")
struct TranscriptEntryIDTests {
    /// **The rule behind giving a row no view at all.** A row measured at nought is given no cell,
    /// which is most of a real session, and the whole safety of that is that a stored row cannot
    /// change what it draws without its content key moving.
    @Test("a stored row does not redraw itself")
    func aRowDoesNotRedrawItself() {
        #expect(!TranscriptEntryID.row(0).redrawsItself)
        #expect(!TranscriptEntryID.row(2_981).redrawsItself)
    }

    /// **The streaming tail is the one that bites.** It draws nothing between turns, so treating
    /// "measured at nought" as "will always be nought" would leave a running turn with no view to
    /// appear in, and the answer would never show up.
    @Test("the four that re-render from their own observation redraw themselves")
    func theOthersRedrawThemselves() {
        #expect(TranscriptEntryID.streaming.redrawsItself)
        #expect(TranscriptEntryID.setup.redrawsItself)
        #expect(TranscriptEntryID.sending.redrawsItself)
        #expect(TranscriptEntryID.pending(DeliveryID("d1")).redrawsItself)
    }

    /// **A fold's line is the case that ended the coincidence below.** It names no stored row, so
    /// it has no sequence number, and it still cannot redraw itself: what it says is hashed into
    /// its content key exactly as a row's is, and it draws nothing at all for most of its life. A
    /// fold measured at nought and then built anyway would be a hosting view per run in the
    /// session, for a line that is not there.
    @Test("a fold's line has no seq and still does not redraw itself")
    func aFoldDoesNotRedrawItself() {
        #expect(!TranscriptEntryID.fold(41).redrawsItself)
        #expect(TranscriptEntryID.fold(41).seq == nil)
    }

    /// This used to read "redrawing itself is exactly having no sequence number", and `fold` is
    /// why it does not any more. What is left of it is the half that is still true.
    @Test("every entry that names a stored row draws only what its key says")
    func rowsDoNotRedrawThemselves() {
        let ids: [TranscriptEntryID] = [
            .setup, .row(7), .fold(7), .sending, .streaming, .pending(DeliveryID("d2")),
        ]
        for id in ids where id.seq != nil {
            #expect(!id.redrawsItself)
        }
    }

    /// A run's first row and the fold's line above it hold the same number and are not the same
    /// entry. They are both in the list at once whenever a run is open, so an id that spelled them
    /// into each other would put the line's height on the row.
    @Test("a fold and the row it names are different entries")
    func aFoldIsNotItsFirstRow() {
        #expect(TranscriptEntryID.fold(12) != TranscriptEntryID.row(12))
        #expect(TranscriptEntryID.fold(12).description == "fold.12")
    }
}
