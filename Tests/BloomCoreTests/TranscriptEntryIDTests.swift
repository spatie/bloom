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
    @Test("the four that are not stored rows all redraw themselves")
    func theOthersRedrawThemselves() {
        #expect(TranscriptEntryID.streaming.redrawsItself)
        #expect(TranscriptEntryID.setup.redrawsItself)
        #expect(TranscriptEntryID.sending.redrawsItself)
        #expect(TranscriptEntryID.pending(DeliveryID("d1")).redrawsItself)
    }

    /// It is the same question `seq` answers, and it has one answer.
    @Test("redrawing itself is exactly having no sequence number")
    func itIsTheSameQuestionAsSeq() {
        let ids: [TranscriptEntryID] = [
            .setup, .row(7), .sending, .streaming, .pending(DeliveryID("d2")),
        ]
        for id in ids {
            #expect(id.redrawsItself == (id.seq == nil))
        }
    }
}
