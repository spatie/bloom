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
    /// same session in two panes, each scrolled somewhere else, and an unsplit tab's pane is
    /// called the same thing in every workspace (see `CenterPanesView.soloPane`), so the session
    /// is what tells two of those apart.
    public struct Key: Hashable, Sendable {
        public var pane: String
        public var session: SessionID

        public init(pane: String, session: SessionID) {
            self.pane = pane
            self.session = session
        }
    }

    /// The width the rows were laid out at and the scale they were drawn at, which are the two
    /// things that decide how tall a row is and so what a point of offset means.
    ///
    /// Optional at both ends, and that is the rule rather than a convenience: a pane that has not
    /// been laid out yet has no width to offer, and a measurement nobody has taken cannot
    /// contradict one that was. The alternative was to treat "not measured" as "different" and
    /// throw away every restored position on the frame the geometry had not landed on yet, which
    /// is most of them.
    public struct Measure: Equatable, Sendable {
        public var width: Double
        public var fontScale: Double

        public init(width: Double, fontScale: Double) {
            self.width = width
            self.fontScale = fontScale
        }
    }

    /// The sequence numbers of the rows the reader had unfolded.
    public var expanded: Set<Int>
    /// Where the view was, in points from the top of the content.
    public var offset: Double
    /// Whether that offset was the live end.
    ///
    /// Kept as a flag rather than inferred from the offset, because a turn can run while the
    /// reader is away: the content grows, and the number of points that meant "the end" when it
    /// was written names somewhere in the middle by the time it is read.
    public var isAtLiveEnd: Bool
    /// How many rows the session held when this was written. See `TranscriptResume.placement`.
    public var rowCount: Int
    public var measure: Measure?

    public init(
        expanded: Set<Int>,
        offset: Double,
        isAtLiveEnd: Bool,
        rowCount: Int,
        measure: Measure?
    ) {
        self.expanded = expanded
        self.offset = offset
        self.isAtLiveEnd = isAtLiveEnd
        self.rowCount = rowCount
        self.measure = measure
    }
}

/// Where a chat pane opens.
public enum TranscriptPlacement: Equatable, Sendable {
    /// Nowhere worth restoring, so the session is opened the way a session has always been opened:
    /// on the first unread row, or on a row somebody searched for, or on the live end.
    case first
    /// The reader left at the live end, so that is where they are put back.
    case liveEnd
    /// The reader left this many points down, and the document is the same document.
    case offset(Double)
}

/// The rule for what a pane may do with what it remembers.
public enum TranscriptResume {
    /// Whether the arrival frame has to draw the whole session rather than `TranscriptTail`'s tail.
    ///
    /// **Asked before anything has been laid out**, because it decides what the FIRST pass of the
    /// list's body draws, so it can read nothing that a measurement has to arrive for. What it may
    /// read is what the pane wrote down when it left, and one field of that settles it.
    ///
    /// **An offset needs the rows above it and the live end does not.** A point down a laid out
    /// document can only be resolved by laying out everything above it, so a pane coming back to
    /// one has to draw the session whole. A pane coming back to the live end is coming back to the
    /// END of the rows, and the end of the tail is the same place as the end of the session: there
    /// is nothing above the viewport that has to exist for it to be where it is.
    ///
    /// This used to answer `remembered != nil`, and drawing in full was the right half of the
    /// trade against the arrangement it replaced. That one drew the tail on the arrival frame and
    /// put the history back a hundred milliseconds later whatever the reader was doing, so a
    /// return cost two main thread stops rather than one, and the second was the larger. Measured
    /// on a release build at 1440 by 900 against a 3,848 row session: 125ms, 125ms and 104ms for
    /// the tail, then 169ms, 163ms and 163ms for the history.
    ///
    /// What was wrong with it was the timer, not the tail. Measured again with `--tab-probe`
    /// against the owner's own 1,011 row session, four warm returns to the chat tab cost 218ms,
    /// 177ms, 128ms and 114ms of stopped main thread, all of it laying out rows thousands of
    /// points above a viewport that opens at the other end of the document. So the tail comes back
    /// for the case where nothing above the viewport is needed, and the history goes back behind
    /// it when the reader asks for it by scrolling towards it rather than on a clock. See
    /// `TranscriptListView.revealHistoryIfNeeded`.
    public static func drawsInFull(_ remembered: TranscriptPaneState?) -> Bool {
        guard let remembered else { return false }
        return !remembered.isAtLiveEnd
    }

    /// Whether this pane is coming back to a session it has drawn before, at the end of it, and so
    /// holds a history it has not drawn and will only draw if the reader goes looking for it.
    ///
    /// The other half of `drawsInFull`, and separate because the two answers are read at different
    /// moments for different reasons: that one decides what the first pass draws, and this decides
    /// whether the list still owes a reveal afterwards. A FIRST open also draws the tail, and it
    /// owes its history on the hundred millisecond timer that has always put it there, because a
    /// reader arriving at a conversation for the first time has an unread mark and a search result
    /// to be able to reach and no written down position saying they were at the end.
    public static func opensOnTheTail(_ remembered: TranscriptPaneState?) -> Bool {
        guard let remembered else { return false }
        return remembered.isAtLiveEnd
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
        rowCount: Int,
        measure: TranscriptPaneState.Measure?
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
        // A point into a document laid out at another width, or at another text size, is a point
        // into a different document. Rather than land the reader at a plausible looking wrong
        // place, this opens the way a fresh visit does.
        if let measure, let was = remembered.measure, was != measure { return .first }
        guard remembered.offset > 0 else { return .first }
        return .offset(remembered.offset)
    }
}
