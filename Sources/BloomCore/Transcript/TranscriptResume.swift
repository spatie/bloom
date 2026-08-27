import Foundation

/// What a chat pane remembers about a conversation while its view does not exist, and what it does
/// with that on the way back.
///
/// **The centre column's panes are destroyed by a tab switch.** `CenterPaneView.content` is a
/// switch on what the pane is showing, so moving from a conversation to the changes takes the whole
/// subtree with it: the scroll view, every row it had realised, and every scrap of the list's own
/// `@State`. Moving back builds all of it again from nothing.
///
/// Measured with `--tab-probe` on a release build at 1440 by 900, against a 3,848 row session,
/// three warm returns to the chat tab. The list restarted in tail mode, drew `TranscriptTail`'s
/// last eighty rows, and a hundred milliseconds later put the whole history back, so the main
/// thread stopped twice: 125ms, 125ms and 104ms for the tail, and then 169ms, 163ms and 163ms for
/// the history. The transcript was not settled until 334ms, 327ms and 333ms after the tab was
/// picked. Drawing the whole session on the arrival frame instead is ONE stop of 209ms, 207ms and
/// 207ms, and the transcript is settled when it ends. Less total work, because the tail is not
/// laid out and then thrown away, and one settle rather than a paint followed by a jump.
///
/// What it is not is cheap. A return to the review tab in the same fixture costs 85ms to 102ms
/// with six milliseconds of centre column layout in it, so most of what is left is the pane being
/// rebuilt at all rather than anything about a transcript. Opening anywhere but the top of a
/// `LazyVStack` realises every row above the target, so a list built from nothing is O(rows)
/// however it is positioned, and the only thing that would make it O(1) is not destroying the
/// view. That is a bigger change than this one and it has a cost of its own: a pane kept alive is
/// a pane laid out on every frame of every window resize.
///
/// It also carries a correctness bug with it, and the same cause: a tool result the reader had
/// unfolded silently re-folded on every tab round trip, because `expanded` was view state and the
/// view was new.
///
/// # The folds and the place are two different claims
///
/// `placement` answers about the place, and the folds are handed back whatever it says, because
/// the two have different lifetimes. A fold is about a row: it survives the pane being made
/// narrower, the text being made bigger and the session growing. An offset is a number of points
/// into a laid out document, and every one of those changes makes it a number into a different
/// document.
public struct TranscriptPaneState: Equatable, Sendable {
    /// One pane's memory of one conversation. Both halves are needed: a split tab can hold the
    /// same session in two panes, each scrolled somewhere else, so the pane alone does not say
    /// which half. The pane string is the tab's own id, which for an unsplit chat tab is already
    /// the session's uuid; nothing is ever keyed on a shared name.
    public struct Key: Hashable, Sendable {
        public var pane: String
        public var session: SessionID

        public init(pane: String, session: SessionID) {
            self.pane = pane
            self.session = session
        }
    }

    /// The sequence numbers of the rows the reader had unfolded.
    public var expanded: Set<Int>
    /// The runs of tool calls the reader had opened, by the sequence number of the first call in
    /// each. See `TranscriptFold`.
    ///
    /// Here rather than in the view for exactly the reason `expanded` is here, and the bug is the
    /// same one: this view is destroyed by every tab switch, so a run somebody opened to read
    /// would fold itself away again the moment they looked at the changes and came back.
    public var unfolded: Set<Int>
    /// Where the view was, in points from the top of the content.
    ///
    /// The fallback, not the answer. See `anchorSeq`.
    public var offset: Double

    /// The row that was at the top of the viewport, by sequence number.
    ///
    /// **A row rather than a point, because a point is not a place here.** The content height of a
    /// transcript is a fact about what the lazy stack has bothered to measure rather than about the
    /// conversation: driven through the owner's own report, one chat visited three times reported
    /// 35,246 points, then 17,235, then 24,407 for the same session. An offset written against one
    /// of those and read against another names a different row.
    ///
    /// Nil when the pane had no row on screen to name, which is an empty conversation and the
    /// frames before the first layout. The offset carries those.
    public var anchorSeq: Int?
    /// How far above that row's top the pane started, which is `TranscriptAnchor.delta`.
    ///
    /// **The row alone puts a reader back at the top of the row they were in, and that is not
    /// where they were.** A single answer is regularly two thousand points tall, so somebody who
    /// left half way down one came back to its first line and had to find their place again. The
    /// pair is what every implementation that has written this down keeps: Element, Zulip, VS Code
    /// and CodeMirror all store an id and an offset within it, and the delta was already being
    /// computed for the in-session case by `TranscriptTable`'s own anchor. It simply was not
    /// written down.
    ///
    /// Usually negative, for the reason `TranscriptAnchor.delta` gives: the row at the top of the
    /// pane is normally part way scrolled off it.
    public var anchorDelta: Double
    /// Whether that offset was the live end.
    ///
    /// Kept as a flag rather than inferred from the offset, because a turn can run while the
    /// reader is away: the content grows, and the number of points that meant "the end" when it
    /// was written names somewhere in the middle by the time it is read.
    public var isAtLiveEnd: Bool
    /// How many rows the session held when this was written. See `TranscriptResume.placement`.
    public var rowCount: Int
    /// The rows the list was drawing when the offset was taken.
    ///
    /// The offset is a number of points into the content, and the content is exactly these rows,
    /// so the two are one measurement and are useless apart: restoring the offset into a window
    /// that holds different rows lands the reader somewhere else. See `TranscriptWindow`.
    public var drawn: TranscriptWindow

    public init(
        expanded: Set<Int>,
        unfolded: Set<Int> = [],
        offset: Double,
        anchorSeq: Int? = nil,
        anchorDelta: Double = 0,
        isAtLiveEnd: Bool,
        rowCount: Int,
        drawn: TranscriptWindow = TranscriptWindow(start: 0, end: 0)
    ) {
        self.expanded = expanded
        self.unfolded = unfolded
        self.offset = offset
        self.anchorSeq = anchorSeq
        self.anchorDelta = anchorDelta
        self.isAtLiveEnd = isAtLiveEnd
        self.rowCount = rowCount
        self.drawn = drawn
    }
}

/// Where a chat pane opens.
public enum TranscriptPlacement: Equatable, Sendable {
    /// Nowhere worth restoring, so the session is opened the way a session has always been opened:
    /// on the first unread row, or on a row somebody searched for, or on the live end.
    case first
    /// The reader left at the live end, so that is where they are put back.
    case liveEnd
    /// The reader left this many points down. The fallback, for a pane that could not name a row.
    case offset(Double)
    /// The reader left this row at the top of the pane, this far above the row's own top, so
    /// that is where they go back. See `TranscriptPaneState.anchorDelta`.
    case row(seq: Int, delta: Double)
}

/// The rule for what a pane may do with what it remembers.
public enum TranscriptResume {
    /// The first row of the session a pane draws, given what it wrote down when it last left one.
    ///
    /// **Asked before anything has been laid out**, because it decides what the FIRST pass of the
    /// list's body draws, so it can read nothing that a measurement has to arrive for.
    ///
    /// This used to answer a Bool, and the Bool was "draw the whole session". The argument for it
    /// was sound and is kept: a pane that has drawn this session before is not arriving at it, so
    /// the tail that keeps a 269ms layout off an arrival frame buys nothing on a return, and
    /// paying a second layout to reveal the history behind it is the trade going the wrong way.
    /// What was wrong was the other end of it. The whole session stays in the lazy stack for the
    /// rest of the visit, and every resize, scroll and streamed token then pays for a stack with
    /// four thousand children in it. See `TranscriptWindow`, which carries those measurements.
    ///
    /// So a return goes back to the window the reader was actually looking at, which is what makes
    /// the remembered offset mean anything: the same rows above the viewport, in the same order,
    /// so the same number of points down the content names the same place. A pane with nothing
    /// written down is arriving, and arrives on the tail.
    /// Whether this pane is coming back to a session rather than arriving at one.
    ///
    /// The existence of a memory for this pane and this session is the whole of it. A reader
    /// coming back is already where they were, so nothing has to be revealed under them and the
    /// window stays exactly as `window` restored it.
    public static func isResuming(_ remembered: TranscriptPaneState?) -> Bool {
        remembered != nil
    }

    public static func window(
        _ remembered: TranscriptPaneState?, tailStart: Int, rowCount: Int
    ) -> TranscriptWindow {
        // A remembered window with no rows in it is not a window anybody was reading in: it is
        // what a pane wrote down before its session had loaded, and restoring it draws a blank
        // transcript. Measured, and caught only because the probe reports how many rows are in the
        // stack: a run that looked like the fastest resize yet was a pane with nothing in it.
        guard let remembered, remembered.drawn.count > 0 else {
            return TranscriptWindow.opening(rowCount: rowCount, tailStart: tailStart)
        }
        return remembered.drawn.clamped(rowCount: rowCount)
    }

    /// Where a pane opens a session, given what it wrote down when it last left one.
    ///
    /// Asked once the list has been laid out, so `measure` is what the pane is now and
    /// `remembered.measure` is what it was. Either being nil means one of the two was never taken.
    ///
    /// Every `.first` below is a case where restoring would put the reader somewhere that is not
    /// where they were, and the arrival that answers instead is not merely a fallback: it opens on
    /// the first unread row, which is what a session nobody has read wants.
    public static func placement(
        for remembered: TranscriptPaneState?,
        rowCount: Int
    ) -> TranscriptPlacement {
        guard let remembered, rowCount > 0 else { return .first }
        // A session with fewer rows than it had is not the session that offset was measured in.
        // Rows are appended and never removed while a pane is away, so this is a transcript that
        // was read again from the start rather than one that grew, and nothing written about the
        // old one carries.
        guard remembered.rowCount <= rowCount else { return .first }
        // The end has moved if a turn ran while the reader was away, and it is still the end. A
        // width change moves nobody who was there, because the end is a place rather than a
        // measurement, so this is asked before the measure is looked at.
        if remembered.isAtLiveEnd { return .liveEnd }
        // **A point measured at another width is used anyway, and that is a reversal.**
        //
        // It used to be refused, on the argument that a point into a document laid out at another
        // width is a point into a different document and landing the reader at a plausible looking
        // wrong place is worse than opening the way a fresh visit does. The first half of that is
        // true and the second half turned out to be the bug the owner reported: opening the way a
        // fresh visit does means opening at the first unread row, and after an agent has worked
        // while somebody was on another workspace, that row is the middle of a long conversation.
        // Roughly where they were beats a screen they have never seen.
        //
        // What would settle it properly is remembering the ROW rather than the point, which
        // survives every width and every re-measurement. SwiftUI will say which row is at the top
        // of a scroll target layout, and measured on this list that layout costs too much to keep:
        // p99 went from 21.8ms to 39.2ms scrolling a 225 row chat with nothing else changed. So
        // the row is what an AppKit list would buy, and until then this is the honest fallback.
        // The row they were reading, which survives every re-measurement and every width, and how
        // far into it they were. See `TranscriptPaneState.anchorSeq`.
        if let seq = remembered.anchorSeq { return .row(seq: seq, delta: remembered.anchorDelta) }
        // **Nought is a place: it is the top of the conversation.** This used to refuse it, on the
        // reasoning that a pane which has never been laid out reports nought and restoring that
        // would be a restore of nothing. The pane not being laid out is a fact about the PANE, and
        // it belongs where the memory is written rather than where it is read: `remember` declines
        // to write anything until the pane has a height. What was left here was a reader who had
        // scrolled to the very top of a long conversation being told they had no place at all, and
        // sent to their first unread row instead. That is the second half of the report.
        return .offset(remembered.offset)
    }

    /// Whether a pane may write down where it is at all.
    ///
    /// **The owner's report was that a workspace switch loses the place, and what it turned out to
    /// be is not a failure to restore it: it is the arriving session overwriting it.** Pointing
    /// this pane at another conversation sets the write target to the session being ARRIVED at and
    /// then suspends on `transcript.load()`. A scroll settling inside that window wrote, under the
    /// arriving session's key, a live end flag forced true by the switch, an anchor of nothing,
    /// and the offset of the conversation being left.
    ///
    /// So the same guard the list's two other after-the-fact writers already had:
    /// `TranscriptListView.growWindow` and `trackArrivals` both open by refusing to act until the
    /// session has finished arriving. `arrived` is the session the pane has settled on and
    /// `writingTo` is the session the measurements belong to, which is deliberately not the one
    /// the model is pointed at now: on the way out of a conversation they are the one being left,
    /// and that write is the one this whole file exists for.
    ///
    /// The other two are unchanged and are about the pane rather than the session: nothing is
    /// written down about a pane that has drawn no rows, or that has never been laid out. Nought
    /// is a real place to a reader at the top of a conversation, so the height is what says a
    /// layout has happened.
    public static func mayRemember(
        arrived: SessionID?, writingTo: SessionID?, drawnRows: Int, paneHeight: Double
    ) -> Bool {
        guard let writingTo, arrived == writingTo else { return false }
        return drawnRows > 0 && paneHeight > 0
    }
}
