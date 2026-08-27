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
/// # The unit is a turn, and it was a stretch of consecutive tool calls
///
/// The owner's words, reading a real transcript: "I expect everything between my blue bubble and
/// the answer of the AI to be grouped. All those items in between." What he was looking at was
/// three short folds where he expected one, because a line of interim narration and a rate limit
/// notice sat between the tool calls and each of them cut the run.
///
/// So the boundaries are the two things a reader navigates by: **their own message, and the turn's
/// answer.** Everything between them is work and folds into one line: tool calls, the agent
/// narrating what it is about to do, thinking, notices, rate limits, a subagent's own rows,
/// and the stream events that draw nothing anyway. Nothing in between is consulted for its kind
/// except to decide where the work ENDS.
///
/// The tool's own name is never consulted, here or in the label, and that is not laziness: the
/// name lives inside the payload, reading it is the decode this whole mechanism exists to avoid,
/// and the prefix sniff that would find it is Claude Code's line shape rather than Codex's.
///
/// # Which prose is the answer
///
/// **The trailing one, and "trailing" is doing the work rather than "last".** A turn can hold two
/// prose blocks with tool calls between them, and the first is narration: it is not what the
/// reader came back to read, so it folds. The answer is the run of rows at the END of the turn
/// that hold nothing a reader would call work, and it is only an answer if there is prose in it.
/// Walking back rather than taking the last prose block is what keeps a turn that says something
/// and then goes back to work as one fold rather than a fold, an answer, and a loose tail.
///
/// Two cases fall out of that and both were asked about:
///
/// - **A turn that ends on a tool call has no answer.** Nothing follows the last work row, so the
///   walk back finds no prose and the whole turn is work. Its newest row stays on screen, which is
///   also what every streaming turn looks like before its answer arrives.
/// - **A turn with two prose blocks and work between them** has one answer, the second, and the
///   first folds with everything around it.
///
/// A streaming turn has not said its answer yet, so its trailing prose is provisional: it is
/// treated as the answer while it is the last thing, and folds in the moment the agent goes back
/// to work. That is the same rule, not an exception, and it is what puts the newest row on screen
/// throughout a turn.
///
/// # What is never hidden
///
/// Four things stop the fold where they are rather than breaking it in two. Everything from the
/// first of them onwards is drawn, and everything before it stays folded.
///
/// 1. **A row whose result has not come back.** What such a row says can still change, and a fold
///    that had to reveal a row it had hidden is a transcript rearranging itself under somebody who
///    is reading it. A tool call with no result yet, and a permission question nobody has answered
///    yet, are the same fact here.
/// 2. **A failed call, and an error row.** A failed command is the one you are scrolling to find,
///    and this is VS Code's `chat.tools.autoExpandFailures` and its default. It stops the fold
///    rather than unfolding what was already folded, so what the reader sees is the line, the
///    failure, and everything after it.
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

    /// What the fold's line says, which has to name what is hidden and how many.
    ///
    /// **Not a count in a grey oval.** That is what was asked for, and macOS has already spent
    /// that shape: Apple's guidance defines a filled oval carrying a number as a notification
    /// badge, reserves it for unread counts and says not to imitate one, and Bloom's own sidebar
    /// draws unread marks a few hundred points to the left. The rule for a disclosure control is
    /// the opposite one, a descriptive label saying what is disclosed or hidden, which a bare
    /// number fails. Every product shipping this exact control puts the count into words: Claude
    /// Code's CLI says "Ran 4 commands", Codex says "Ran 4 commands", Cursor says "Explored N
    /// tools".
    ///
    /// **It said "tool calls" and cannot any more**, because what is hidden is now a turn's whole
    /// working: calls, the narration between them, thinking, a notice. "Step" is what covers all
    /// of those and it is the word every agent surface uses for exactly this. It is not the
    /// todo list's "step": that one is a thing the agent PLANS to do, this one is a thing it has
    /// already done, and they never appear in the same place.
    ///
    /// Two wordings, for two different claims rather than for variety. While a turn is working
    /// there is a row of it still on screen, so the hidden ones are the ones above it and the line
    /// says so. Once the answer has landed the whole of the working is behind the line, and there
    /// is no "earlier" left for the word to mean.
    public static func label(hiding count: Int, showsMore: Bool) -> String {
        let unit = count == 1 ? "step" : "steps"
        return showsMore ? "\(count) earlier \(unit)" : "\(count) \(unit)"
    }

    /// An opened live turn becomes a growing log again when another item arrives. At the live end,
    /// fold it back so the newest item remains visible and the completed items return to their
    /// count. Away from the end the reader is inspecting that log, so their disclosure stays open.
    public static func refoldedAtLiveEnd(_ unfolded: Set<Int>, in folds: Folds) -> Set<Int> {
        guard let live = folds.all.last, !live.hasAnswer, unfolded.contains(live.firstSeq) else {
            return unfolded
        }
        var result = unfolded
        result.remove(live.firstSeq)
        return result
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
        // The last row stays while the turn has not said its answer yet: it is the thing happening
        // now, and hiding it is the one way this feature can take away what it was asked for. Once
        // the answer is on screen there is nothing left to keep, so the whole working goes.
        var count = min(work.ready, work.hasAnswer ? work.rows.count : work.rows.count - 1)
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
            drawsNothing: Bool = false,
            settled: Bool = true
        ) {
            self.seq = seq
            self.kind = kind
            self.failed = failed
            self.drawsNothing = drawsNothing
            self.settled = settled
        }

        /// Whether this row is one a reader would call work, which is what the walk back from the
        /// end of a turn stops at. Prose, a notice and anything that draws nothing are not.
        var isWork: Bool {
            switch kind {
            case .toolUse, .thinking, .permissionAsk, .error: !drawsNothing
            case .assistantText, .notice, .system, .user, .toolResult, .result: false
            }
        }

        /// Whether this row has to stay on screen once it is reached. See rule 2 in the header.
        var mustShow: Bool { failed || kind == .error }
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

    /// One row of a turn as the scan is carrying it: where it is, and the three questions the
    /// walk back at the end of a turn asks about it.
    ///
    /// Beside the other types rather than inside `folds(in:extending:)`, which is where it reads
    /// best and where Swift will not have it: a type cannot be nested in a generic function. A
    /// struct rather than a tuple, because the walk maps over one field and there is no key path
    /// into a tuple either.
    private struct Item {
        var row: Row
        /// Whether a reader would call this row work, which is what the walk back stops at.
        var isWork: Bool
        var isProse: Bool
        /// Whether this row may be hidden: settled, and not one that has to stay.
        var ready: Bool
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
        /// waiting be hidden behind one that has landed. It stops at the first row that has not
        /// settled or must stay, and it never goes backwards, which is what makes the fold
        /// monotone.
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

        // The turn being built. `items` is every row of it that draws something, carrying what the
        // walk back at the end needs to know about each.
        var turnStart = 0
        var items: [Item] = []
        var resume = start

        func close() {
            defer { items = [] }
            // The answer: the rows at the end of the turn that hold no working, and only an answer
            // if there is prose among them. See the header for why this walks back rather than
            // taking the last prose block.
            var end = items.count
            while end > 0, !items[end - 1].isWork { end -= 1 }
            let hasAnswer = items[end...].contains { $0.isProse }
            let working = hasAnswer ? Array(items[..<end]) : items
            guard working.count >= leastWork, let last = working.last else { return }
            // The prefix stops at the first row that could still change or that has to stay.
            var ready = 0
            while ready < working.count, working[ready].ready { ready += 1 }
            found.append(Work(
                span: turnStart..<(last.row.index + 1),
                rows: working.map(\.row),
                ready: ready,
                hasAnswer: hasAnswer
            ))
        }

        for offset in start..<count {
            let fact = facts[facts.index(facts.startIndex, offsetBy: offset)]
            // The two boundaries a reader navigates by. Neither is inside a fold, and both settle
            // everything above them.
            if fact.kind == .user || fact.kind == .result {
                close()
                resume = offset + 1
                continue
            }
            // A row that draws nothing is not a row the reader can see, so it is swallowed by
            // whatever is folded around it and counted as nothing. See `TranscriptRowInk`.
            if fact.drawsNothing { continue }
            if items.isEmpty { turnStart = offset }
            items.append(Item(
                row: Row(index: offset, seq: fact.seq),
                isWork: fact.isWork,
                isProse: fact.kind == .assistantText,
                // **A failure counts as settled whatever the caller said, and that is the invariant
                // the monotonicity rests on.** A result writes `is_error` and the payload in one
                // go, so a call cannot have failed without having settled; read the other way
                // round, a row that is hidden has already settled and can therefore never turn into
                // a failure afterwards.
                ready: (fact.settled || fact.failed) && !fact.mustShow
            ))
        }
        // Whatever is left at the end is a turn that is still running, and it is treated exactly
        // like any other: folding while the turn works is the point, and the entry has to be in the
        // list before it folds.
        close()

        return Folds(all: found, scannedRows: count, resumeIndex: min(resume, count))
    }
}
