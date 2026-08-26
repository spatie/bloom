import BloomCore
import SwiftUI

/// Which rows of the transcript have only just turned up, kept where a cell can ask on the frame
/// it is built.
///
/// **The rules are `RowArrival`'s and the timing is here, because a table builds its cells at a
/// different moment from a lazy stack.**
///
/// In the stack a row asks during the pass that creates it, and `TranscriptListView` could hold
/// the tracker as `@State` and read it in the body. A table cannot: the entries are assembled in
/// the body, handed to `updateNSView`, and the cells for the rows that arrived are built by AppKit
/// during the layout that follows. If the answer were baked into the entry as the body ran, it
/// would be the answer from before `trackArrivals` had seen the new list, and the row would be
/// told it was not arriving. That is the same mistake the lazy stack made in a different place and
/// filmed against a real turn: twenty-three rows built, twenty-three of them told they were not
/// arriving, and no row in the transcript ever settled. There the fix was to ask the tracker for
/// a set difference rather than for "have I seen this row"; here it is to ask it later.
///
/// So the entry's closure asks THIS object when the cell is built, which is after the row count's
/// `onChange` has run whichever order SwiftUI chose for the two. A reference rather than a value
/// for the reason `TranscriptHoverHost` and `GeometryBox` are references: it is written on every
/// row that lands and read by nothing that draws from a body, so keeping it out of `@State` is
/// what stops a row landing re-running the pass that assembles four thousand closures.
///
/// It is not `@Observable` either, and that is the same point said once more. Nothing should be
/// invalidated by a row arriving except the cell that arrived.
@MainActor
final class TranscriptArrivals {
    /// How many rows at the live end the tracker is shown.
    ///
    /// The set difference only ever has to see the end of the list: rows are appended and never
    /// reordered, so an id that falls out of this window cannot come back and be mistaken for
    /// something new. Handing it a four thousand row session instead would build four thousand
    /// entries in a set every time one row lands.
    static let window = 200

    /// Keyed on the sequence number itself rather than on a string of it. A row asks on every
    /// build rather than only when the tracker has something to say, and a question asked that
    /// often must not allocate to be asked.
    private var arrival = RowArrival<Int>()
    private var settle: Task<Void, Never>?

    /// Takes the list in and works out what is new about it.
    func absorb(_ seqs: some Sequence<Int>) {
        arrival.absorb(seqs)
        scheduleSettle()
    }

    /// Takes the list in with nothing arriving out of it.
    ///
    /// A session's history does not fade. Switching workspaces hands this pane eighty rows in one
    /// frame and the rest of the history a beat later, and neither is work turning up in front of
    /// the reader: it is the pane being pointed somewhere else.
    func adopt(_ seqs: some Sequence<Int>) {
        settle?.cancel()
        settle = nil
        arrival.adopt(seqs)
    }

    func isArriving(_ seq: Int) -> Bool {
        arrival.isArriving(seq)
    }

    /// Closes the window during which these rows count as having just turned up.
    ///
    /// Scheduled here rather than through `settlesArrivals`, which the sidebar and Home use: that
    /// modifier hangs a `task(id:)` off the tracker's own set, which needs the tracker to be
    /// `@State` and observed, which is exactly what this type exists not to be.
    ///
    /// Two hundred milliseconds, which is a margin rather than a measurement, and the same margin
    /// `ArrivalSettle` uses. The fade does not wait for it: `ArrivingRow` latches on its own
    /// `onAppear`, and by then the row is on screen and the tracker's answer no longer matters to
    /// it. What this bounds is how long the answer stays yes, so that a row scrolled out of a long
    /// conversation and back months later is not greeted as a new arrival.
    private func scheduleSettle() {
        settle?.cancel()
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            settle = nil
            arrival.settle()
        }
    }
}
