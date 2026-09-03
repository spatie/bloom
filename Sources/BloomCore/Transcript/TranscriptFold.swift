import Foundation

/// A turn's work, folded down to one line and whatever of it the reader still needs to see.
///
/// **This is a performance fix wearing a disclosure triangle, and the shape follows from that.**
/// The list handed to the table is `entries`, the table's row count is `entries.count`, and every
/// entry is keyed, given a height, offered a view and walked by `TranscriptEntryChange`. A turn of
/// forty rows that draws as two entries is thirty-eight rows that are never keyed, never measured
/// and never built. Hiding views inside a `DisclosureGroup` would have kept every one of those
/// costs and bought nothing, so the fold happens here, in the list, before the table ever sees it.
///
/// # The unit is consecutive activity
///
/// Grey activity rows are the implementation log: tool calls, thinking, notices and settled
/// questions. Consecutive rows of that kind fold into one line. Black assistant prose is the
/// useful account of what the agent found or intends to do, so every prose row remains visible and
/// divides the activity before and after it into separate groups.
///
/// The tool's own name is never consulted, here or in the label, and that is not laziness: the
/// name lives inside the payload, reading it is the decode this whole mechanism exists to avoid,
/// and the prefix sniff that would find it is Claude Code's line shape rather than Codex's.
///
/// A prose row closes the activity above it as answered. Activity after that prose starts a fresh
/// live group. This distinction lets a live group refold when another log row arrives without ever
/// taking prose away from the reader.
///
/// # What is never hidden
///
/// Four things remain visible. Permanent outcomes split consecutive activity into a new fold;
/// temporary or reader-selected rows cap the current fold without rearranging it.
///
/// 1. **A row whose result has not come back.** What such a row says can still change, and a fold
///    that had to reveal a row it had hidden is a transcript rearranging itself under somebody who
///    is reading it. A tool call with no result yet, and a permission question nobody has answered
///    yet, are the same fact here.
/// 2. **A failed call, and an error row.** A failed command is the one you are scrolling to find.
///    It remains visible and divides the ordinary activity before and after it into separate
///    compact groups.
/// 3. **A permission question nobody has answered.** It is covered by 1, and it is written down
///    separately because burying a question the turn is stopped on would be the worst fault this
///    file could have. Answered, it folds away with the rest.
/// 4. **A row something has asked to be visible**: a tool result the reader opened, and the row
///    this session was opened on. The last of those is worse than cosmetic, because a scroll can
///    only find a row the table is DRAWING, so a search hit or an unread mark inside a fold is not
///    a row somewhere off screen, it is a scroll that lands nowhere at all.
///
/// **Every one of them is a stopping point rather than a refusal**, and that is the property the
/// rest of this file is arranged around: what a fold hides only ever grows.
public enum TranscriptFold {
    /// The fewest rows worth hiding.
    ///
    /// A fold costs one line for itself, so hiding N rows saves N minus one: at one it saves
    /// nothing whatsoever, at two it saves a single line in exchange for a control and a decision,
    /// and at three it starts to pay. Three is also about as much as a reader takes in at a glance
    /// (read the file, change it, check it), which is a thought rather than a log.
    public static let leastHidden = 3

    /// How many rows a turn's work needs before its fold gets an entry in the list at all.
    ///
    /// **Deliberately less than `leastHidden`, and that gap is load bearing.** The fold's line is
    /// an entry of its own, and an entry appearing in the middle of the list on the same pass that
    /// rows leave it is two edits `TranscriptEntryChange` can only answer `.rebuilt` to. In the
    /// list from the second row of the work onwards, drawing nothing until there is something to
    /// say, the pass that folds a turn is a removal and nothing else.
    public static let leastWork = 2

    /// What a fold says to accessibility and places that do not draw the count badge.
    ///
    /// `Counted` rather than a ternary of its own. It carried a `showsMore` parameter that no
    /// branch here ever read, which is the shape of a rule that has been copied: the caller passes
    /// what the other copy needs and this one quietly ignores it.
    ///
    /// **`TranscriptFoldRowView` does not call this yet, and should.** It draws the noun as a bare
    /// `Text("actions")` beside the count in the glyph and labels the row
    /// `"\(hiddenCount) actions"`, so a fold hiding one row is announced as "1 actions".
    public static func label(hiding count: Int) -> String {
        Counted.of(count, "action")
    }

    /// An opened live turn becomes a growing log again when another item arrives. At the live end,
    /// fold it back so the newest item remains visible and the completed items return to their
    /// count. Away from the end the reader is inspecting that log, so their disclosure stays open.
    public static func refoldedAtLiveEnd(_ unfolded: Set<Int>, in folds: Folds) -> Set<Int> {
        let live = folds.all.reversed().prefix { !$0.hasAnswer }.map(\.firstSeq)
        guard live.contains(where: unfolded.contains) else { return unfolded }
        var result = unfolded
        result.subtract(live)
        return result
    }

    /// Whether folds scanned on the same pass the rows arrived may be drawn on that pass, rather
    /// than waiting for the one `TranscriptListView` gives them.
    ///
    /// **The jar this answers.** The runs are refreshed one pass behind the row that changed them,
    /// which is what keeps each event a single-shape edit: an arrival is a `.grew` on its own and a
    /// fold closing is a `.shrank` on its own, and `TranscriptEntryChange` can only call a pass
    /// that does both `.rebuilt`. The cost of that split is a frame: the moment a call's result
    /// lands, the call is settled and still drawn, and it folds away on the pass after. On a tool
    /// that takes tens of milliseconds the reader sees the row appear and then jump into the
    /// count, which was reported as jarring and is.
    ///
    /// So the split is kept for the passes that need it and dropped for the ones that do not. The
    /// only pass this says yes to is one where **nothing becomes newly exposed**: rows leave the
    /// tail and none arrive in it, which is a removal by itself whichever pass it happens on. The
    /// case it still refuses is the batched one, where a result and the next call land together:
    /// there the old tail row goes and a new one takes its place, a middle of the same length with
    /// different ids, which is exactly `.rebuilt`.
    ///
    /// - Parameter drawn: the window of rows the list is handing to the table. A fresh fold whose
    ///   working runs past it cannot be adopted, and this is not a detail: `hides` refuses to fold
    ///   a working the window stops inside, so adopting one would UNFOLD the turn for a pass. The
    ///   window grows on the same event, one pass behind, exactly as these do.
    public static func mayAdopt(_ fresh: Folds, over stale: Folds, drawn: Range<Int>) -> Bool {
        // A turn's first fold appearing is an insertion in the middle of the list, which is the
        // one shape `Folds` documents as a reload. It is left to the pass that already handles it.
        guard fresh.all.count == stale.all.count,
              let new = fresh.all.last, let old = stale.all.last,
              new.firstSeq == old.firstSeq,
              new.span.upperBound <= drawn.upperBound else { return false }

        return lastExposedSeq(new) <= lastExposedSeq(old)
    }

    /// The sequence number of the last row this working leaves on screen, or `Int.min` for one
    /// that leaves none. Rows are only ever appended, so a working that exposes a higher sequence
    /// number than it did is a working that has gained an exposed row.
    private static func lastExposedSeq(_ work: Work) -> Int {
        guard work.ready < work.rows.count, let last = work.rows.last else { return .min }
        return last.seq
    }

    /// How many rows at the front of this turn's work are hidden right now, or nought for a fold
    /// that is not folded.
    ///
    /// **A prefix that only grows, which is the whole of why nothing unfolds under a reader.**
    /// Every term moves in one direction only: results arrive and never un-arrive, questions get
    /// answered and never unanswered, rows are appended and never removed, and `revealed` only ever
    /// gains a row that is already on screen. So the answer for a given turn never goes down.
    ///
    /// `revealed` is every sequence number something has asked to be visible: the tool results the
    /// reader has opened, and the row this session was opened on. `drawn` is the window of rows the
    /// list is handing to the table, because a fold has to be able to draw what it leaves.
    public static func hides(_ work: Work, revealed: Set<Int>, drawn: Range<Int>) -> Int {
        // Settled work can all move into the fold. Its newest row remains visible as the fold's
        // label, so this compacts the transcript without taking the current activity away.
        var count = min(work.ready, work.rows.count)
        // Cut short at the first row somebody is reading or being taken to, rather than refusing to
        // fold at all: refusing would unfold a turn that had already folded.
        if !revealed.isEmpty,
           let stop = work.rows.prefix(count).firstIndex(where: { revealed.contains($0.seq) }) {
            count = stop
        }
        guard count >= leastHidden else { return 0 }
        // A window that stops inside the working cannot fold it: the rows it would leave are rows
        // the table is not drawing, and the line would stand over nothing. Only the window's END is
        // asked about, because its start only ever moves down and what is hidden is an absolute
        // range of rows rather than one measured from the window.
        guard work.span.upperBound <= drawn.upperBound else { return 0 }
        return count
    }

    /// One row, in the only terms the fold cares about.
    ///
    /// A projection rather than the row itself, because `TranscriptRow` lives in the app target
    /// and because every field here is free: the payload is never read except through
    /// `TranscriptRowInk`, which sniffs its first bytes.
    public struct Fact: Equatable, Sendable {
        public var seq: Int
        public var kind: MessageKind
        /// The call reported an error or was refused. Both travel as `is_error`, so they are one
        /// fact here.
        public var failed: Bool
        /// Deliberate content carried by an activity-shaped row, such as inline media. It remains
        /// visible and separates the ordinary implementation log on either side.
        public var featured: Bool
        /// What `TranscriptRowInk` says, which is that most `system` rows draw no view at all.
        public var drawsNothing: Bool
        /// **Nothing this row says can change again**, which is the whole of what lets a fold hide
        /// it while the turn is still running.
        ///
        /// False for a tool call whose result has not come back, and false for a permission
        /// question nobody has answered. True for everything else, because a row of prose is
        /// finished the moment it is stored. `failed` implies it, and the scan enforces that rather
        /// than trusting the caller: a result writes `is_error` and the payload in one go, so a
        /// call that could fail after being hidden would be a fold that has to unfold.
        public var settled: Bool

        public init(
            seq: Int,
            kind: MessageKind,
            failed: Bool = false,
            featured: Bool = false,
            drawsNothing: Bool = false,
            settled: Bool = true
        ) {
            self.seq = seq
            self.kind = kind
            self.failed = failed
            self.featured = featured
            self.drawsNothing = drawsNothing
            self.settled = settled
        }

        /// Whether this is a grey activity row that may belong to a compact group. Black prose and
        /// the structural rows around a turn are boundaries.
        var isActivity: Bool {
            switch kind {
            case .toolUse, .thinking, .permissionAsk, .notice, .system, .error: !drawsNothing
            // A crew row is somebody talking, so it is a boundary like the other two are. Folding
            // it into a group of grey working rows would hide the message that started the work.
            case .assistantText, .user, .toolResult, .result, .crew: false
            }
        }

        /// Whether this row has to stay on screen once it is reached. See rule 2 in the header.
        var mustShow: Bool { failed || featured || kind == .error }
    }

    /// One row of a turn's working: where it is, and what it is called.
    ///
    /// The index answers "is this row hidden", which is a comparison against the first row that
    /// stays. The seq answers "is this the row somebody asked to see", which arrives as a set of
    /// sequence numbers from the view. Both are needed and neither can be derived from the other.
    public struct Row: Equatable, Sendable {
        public var index: Int
        public var seq: Int

        public init(index: Int, seq: Int) {
            self.index = index
            self.seq = seq
        }
    }

    /// One row of activity as the scan is carrying it.
    ///
    /// Beside the other types rather than inside `folds(in:extending:)`, which is where it reads
    /// best and where Swift will not have it: a type cannot be nested in a generic function. A
    /// struct rather than a tuple, because the walk maps over one field and there is no key path
    /// into a tuple either.
    private struct Item {
        var row: Row
        /// Whether this row may be hidden: settled, and not one that has to stay.
        var ready: Bool
        /// A permanent boundary inside a turn, such as a failed call. Activity after it starts a
        /// fresh fold instead of remaining exposed for the rest of the turn.
        var mustShow: Bool
    }

    /// One turn's working, as the list needs it.
    public struct Work: Equatable, Sendable {
        /// The rows the working spans, as indices into the session's rows. The rows between them
        /// that draw nothing are inside it; the answer is not.
        public var span: Range<Int>
        /// Every row of the working that draws something, in order.
        public var rows: [Row]
        /// How many rows from the front may be hidden.
        ///
        /// A prefix rather than a count, because a gap in the middle would let a row that is still
        /// waiting be hidden behind one that has landed. Permanent visible rows are not part of
        /// this work segment. It stops at the first row that has not settled, and it never goes
        /// backwards, which is what makes the fold monotone.
        public var ready: Int
        /// Whether the turn has said its answer, so nothing of the working need stay on screen.
        public var hasAnswer: Bool

        /// The fold's identity, which is the sequence number of the FIRST row of the working.
        ///
        /// **The first rather than the last, and it is the whole reason a growing turn is cheap.**
        /// The fold's own entry sits at the head of the working and is in the list from the moment
        /// there are `leastWork` rows in it, folded or not, so folding removes rows after an entry
        /// that was already there and `TranscriptEntryChange` answers `.shrank`. Named by the last
        /// row instead, the entry would move every time one arrived.
        public var firstSeq: Int { rows.first?.seq ?? 0 }

        public init(span: Range<Int>, rows: [Row], ready: Int, hasAnswer: Bool) {
            self.span = span
            self.rows = rows
            self.ready = ready
            self.hasAnswer = hasAnswer
        }
    }

    /// Every turn's working in a session, and where a rescan may start from.
    ///
    /// **Held by the list rather than recomputed in its body, and that is not only about cost.**
    /// A pass that both inserted a row and folded a turn away is two edits in one list, which
    /// `TranscriptEntryChange` cannot say as a single run of indices, so it answers `.rebuilt` and
    /// the table throws away every cell and the reader's text selection with them. Recomputed one
    /// pass later, the arrival is a `.grew` on its own and the fold is a `.shrank` on its own, and
    /// neither costs a reload. See `TranscriptListView`, where the recompute hangs off the row
    /// count.
    ///
    /// **One shape is still a reload, and it is left in on purpose.** A turn born with more than
    /// `leastHidden` settled rows in a single pass has no line in the list for the removal to hang
    /// off, so that pass is an insertion and a removal at once. Rule 1 is what makes it unreachable
    /// in practice: rows the CLI writes in a burst are a message's parallel tool calls, and those
    /// arrive with no results at all, so they are drawn until the results land and the line is in
    /// the list by then. What is left needs the main thread stalled across a turn boundary.
    /// Defending it would mean carrying "was this turn already listed" from scan to scan, which is
    /// history this type deliberately does not keep: everything here is a function of the rows as
    /// they are now, plus an index saying where a rescan may start.
    public struct Folds: Equatable, Sendable {
        public var all: [Work]
        /// How many rows produced this, so a rescan can tell an append from a new session.
        public var scannedRows: Int
        /// Where the next scan starts, which is just past the last row that ENDED a turn.
        ///
        /// Only a user's message and a turn's result row settle everything above them. A turn that
        /// is still running has a working whose answer is provisional and whose settled prefix is
        /// about to grow, so it is rescanned in full every time a row lands. A turn is a few
        /// hundred rows at worst and the facts are read off the row rather than out of its payload.
        public var resumeIndex: Int

        public static let none = Folds(all: [], scannedRows: 0, resumeIndex: 0)

        public init(all: [Work], scannedRows: Int, resumeIndex: Int) {
            self.all = all
            self.scannedRows = scannedRows
            self.resumeIndex = resumeIndex
        }

        /// Where in `all` the working holding this row index is, or nothing.
        ///
        /// A binary search rather than a scan, because the list asks it once per row of the window
        /// on every pass that assembles the entries.
        ///
        /// **An index rather than the value, and that is the per-row cost rather than a style.** A
        /// `Work` carries an array, so handing one back is a retain and a release on every row of
        /// the window on every pass. The caller takes the value once per TURN, where it needs the
        /// rows, and asks this question with nothing to release.
        public func index(containing index: Int) -> Int? {
            var low = 0
            var high = all.count
            while low < high {
                let middle = low + (high - low) / 2
                if all[middle].span.upperBound <= index {
                    low = middle + 1
                } else if index < all[middle].span.lowerBound {
                    high = middle
                } else {
                    return middle
                }
            }
            return nil
        }

        /// The working this row index belongs to, or nothing.
        public func fold(containing index: Int) -> Work? {
            self.index(containing: index).map { all[$0] }
        }
    }

    /// The workings in a session, extending what was already known about it.
    ///
    /// Rows are appended and never reordered, so everything below `previous.resumeIndex` is
    /// settled and only the last turn is rescanned. Handed a shorter list than last time, which is
    /// a session being replaced rather than grown, it starts again from nothing.
    public static func folds<Facts: RandomAccessCollection>(
        in facts: Facts, extending previous: Folds = .none
    ) -> Folds where Facts.Element == Fact, Facts.Index == Int {
        let count = facts.count
        var start = previous.resumeIndex
        var found: [Work] = []
        if count < previous.scannedRows || start > count {
            start = 0
        } else {
            found = previous.all.filter { $0.span.upperBound <= start }
        }

        // The consecutive activity being built. Black prose and structural turn rows close it.
        var items: [Item] = []
        var resume = start

        func close(hasAnswer: Bool) {
            defer { items = [] }
            var segmentStart = items.startIndex

            func appendSegment(endingAt segmentEnd: Int) {
                let segment = items[segmentStart..<segmentEnd]
                guard segment.count >= leastWork,
                      let first = segment.first,
                      let last = segment.last else { return }
                var ready = 0
                while ready < segment.count,
                      segment[segment.index(segment.startIndex, offsetBy: ready)].ready {
                    ready += 1
                }
                found.append(Work(
                    span: first.row.index..<(last.row.index + 1),
                    rows: segment.map(\.row),
                    ready: ready,
                    hasAnswer: hasAnswer
                ))
            }

            for index in items.indices where items[index].mustShow {
                appendSegment(endingAt: index)
                segmentStart = items.index(after: index)
            }
            appendSegment(endingAt: items.endIndex)
        }

        for offset in start..<count {
            let fact = facts[facts.index(facts.startIndex, offsetBy: offset)]
            // A message and the footer settle everything above them. Neither belongs to an
            // activity group, and a crew row is a message: it is what another agent said to start
            // this turn, in the place a user row sits when a person started it.
            if fact.kind == .user || fact.kind == .crew || fact.kind == .result {
                close(hasAnswer: false)
                resume = offset + 1
                continue
            }
            // Black assistant prose is content, never log noise. It remains visible and closes the
            // grey activity above it as answered. Any activity after it starts a fresh group.
            if fact.kind == .assistantText {
                close(hasAnswer: true)
                continue
            }
            // A row that draws nothing is not a row the reader can see, so it is swallowed by
            // whatever is folded around it and counted as nothing. See `TranscriptRowInk`.
            if fact.drawsNothing { continue }
            guard fact.isActivity else { continue }
            items.append(Item(
                row: Row(index: offset, seq: fact.seq),
                // **A failure counts as settled whatever the caller said, and that is the invariant
                // the monotonicity rests on.** A result writes `is_error` and the payload in one
                // go, so a call cannot have failed without having settled; read the other way
                // round, a row that is hidden has already settled and can therefore never turn into
                // a failure afterwards.
                ready: fact.settled || fact.failed,
                mustShow: fact.mustShow
            ))
        }
        // Whatever is left is live activity. Folding while the turn works is the point, and the
        // entry has to be in the list before it folds.
        close(hasAnswer: false)

        return Folds(all: found, scannedRows: count, resumeIndex: min(resume, count))
    }
}
