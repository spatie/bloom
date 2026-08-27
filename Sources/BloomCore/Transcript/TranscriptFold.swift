import Foundation

/// A run of consecutive tool calls, folded down to the last of them and a line saying how many
/// came before it.
///
/// **This is a performance fix wearing a disclosure triangle, and the shape follows from that.**
/// The list handed to the table is `entries`, the table's row count is `entries.count`, and every
/// entry is keyed, given a height, offered a view and walked by `TranscriptEntryChange`. A run of
/// seven that draws as one entry is six rows that are never keyed, never measured and never built.
/// Hiding views inside a `DisclosureGroup` would have kept every one of those costs and bought
/// nothing, so the fold happens here, in the list, before the table ever sees it.
///
/// # What forms a run
///
/// Consecutive `toolUse` rows at one nesting level. Everything the reader would have read breaks a
/// run: prose, thinking, a user turn, a permission question, an error, a notice, a turn's result
/// row, an orphaned tool result, and a session start. What draws nothing does not break one:
/// sixty per cent of a real session is `system` rows with three to five of them between every pair
/// of tool calls, and a rule that let those break a run would find no runs at all. See
/// `TranscriptRowInk`, which is where "draws nothing" is decided and which is deliberately a sniff
/// rather than a decode.
///
/// A mixed run joins. `Read`, then five `Bash`, with an `Edit` in the middle of them, is the case
/// the owner was looking at when he asked for this, and cutting it at the `Edit` would leave two
/// short runs and three rows on screen where the whole point was to leave one. The tool's own name
/// is not consulted at all, here or in the label, and that is not laziness: the name lives inside
/// the payload, reading it is the decode this whole mechanism exists to avoid, and the prefix
/// sniff that would find it is Claude Code's line shape rather than Codex's.
///
/// # When a run refuses to fold
///
/// **A run that is still growing does not fold.** The rows arriving during a turn are what the
/// reader is watching, and folding them under somebody who is reading them is the complaint
/// Cursor's users made loudly when it collapsed against their setting. So a run folds only once
/// something the reader can see has landed after it, which is also the moment every tool result in
/// it has arrived, since the CLI writes a call, then its result, then the next call.
///
/// **A run holding a failure does not fold**, which is VS Code's `chat.tools.autoExpandFailures`
/// and its default. A failed command is the one you are scrolling to find. The failure does not
/// cut the run in two, it only stops it folding: a result marking a call failed arrives after the
/// call, and a rule that re-cut the runs would move a fold's identity out from under the table.
///
/// **A run holding a row something has asked to be visible does not fold.** That is a tool result
/// the reader opened, a search hit, and the unread mark a session opens on. The first is somebody
/// reading; the last two are worse than cosmetic, because a scroll can only find a row the table
/// is drawing, so folding a search hit away would take the reader nowhere at all.
public enum TranscriptFold {
    /// The shortest run worth folding, counted in rows that draw something.
    ///
    /// A fold costs one line for its own header, so a run of N leaves N minus one on screen: at
    /// two it saves nothing whatsoever, at three it saves a single line in exchange for a control
    /// and a decision, and at four it halves the run. Three is also about as much as a reader
    /// takes in at a glance (read the file, change it, check it), which is a thought rather than a
    /// log. So four.
    public static let leastRun = 4

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
    /// "Commands" is theirs and cannot be ours, because a run here mixes `Read`, `Edit` and `Bash`
    /// and five of those are not five commands. "Tool call" is what the rest of this app calls
    /// one, from `AgentToolUse` down to `ToolRowHeader`, and it is true of every run whatever it
    /// holds. "Earlier" is doing work too: the row still on screen is the LAST of the run, so the
    /// hidden ones are the ones above it.
    ///
    /// The same words whether the fold is open or shut. A disclosure label names what is behind
    /// it, which does not change when it is opened, and a row whose text swapped on every click
    /// would read as two different rows.
    public static func label(hiding count: Int) -> String {
        count == 1 ? "1 earlier tool call" : "\(count) earlier tool calls"
    }

    /// Whether this run is drawn folded right now.
    ///
    /// `revealed` is every sequence number something has asked to be visible: the tool results the
    /// reader has opened, the row a search is aiming at, and the unread mark. `drawn` is the
    /// window of rows the list is handing to the table, and a run whose last row falls outside it
    /// cannot fold, because the row a fold keeps on screen has to be a row that is being drawn.
    public static func isFolded(
        _ run: Run, unfolded: Set<Int>, revealed: Set<Int>, drawn: Range<Int>
    ) -> Bool {
        guard run.canFold, !unfolded.contains(run.firstSeq) else { return false }
        guard drawn.contains(run.lastDrawnIndex) else { return false }
        return !revealed.contains { run.seqs.contains($0) }
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
        /// The row came from inside a subagent. A change of nesting breaks a run: two indent
        /// levels folded into one line would be a fold that lies about where its rows were.
        public var nested: Bool
        /// What `TranscriptRowInk` says, which is that most `system` rows draw no view at all.
        public var drawsNothing: Bool

        public init(
            seq: Int, kind: MessageKind, failed: Bool, nested: Bool, drawsNothing: Bool
        ) {
            self.seq = seq
            self.kind = kind
            self.failed = failed
            self.nested = nested
            self.drawsNothing = drawsNothing
        }
    }

    /// One run, as the list needs it.
    public struct Run: Equatable, Sendable {
        /// The rows the run spans, as indices into the session's rows. Interior rows that draw
        /// nothing are inside it.
        public var rows: Range<Int>
        /// The first and last member's sequence numbers, for asking whether a seq is inside.
        public var seqs: ClosedRange<Int>
        /// The row a folded run still shows, which is the last call in it.
        public var lastDrawnIndex: Int
        /// How many drawing rows the fold hides, which is every member but the last.
        public var hiddenCount: Int
        /// Whether it may fold at all: long enough, closed, and holding no failure.
        public var canFold: Bool

        /// The fold's identity, which is the sequence number of the FIRST call in it.
        ///
        /// **The first rather than the last, and it is the whole reason expanding one is cheap.**
        /// The fold's own entry sits immediately before the run and is in the list from the moment
        /// the run is long enough, folded or not, so opening one inserts rows after an entry that
        /// was already there and `TranscriptEntryChange` answers `.grew`. Named by the last call
        /// instead, the entry would move every time the run grew.
        public var firstSeq: Int { seqs.lowerBound }

        public init(
            rows: Range<Int>,
            seqs: ClosedRange<Int>,
            lastDrawnIndex: Int,
            hiddenCount: Int,
            canFold: Bool
        ) {
            self.rows = rows
            self.seqs = seqs
            self.lastDrawnIndex = lastDrawnIndex
            self.hiddenCount = hiddenCount
            self.canFold = canFold
        }
    }

    /// Every run in a session, and where a rescan may start from.
    ///
    /// **Held by the list rather than recomputed in its body, and that is not only about cost.**
    /// A pass that both inserted a row and folded a run away is two edits in one list, which
    /// `TranscriptEntryChange` cannot say as a single run of indices, so it answers `.rebuilt` and
    /// the table throws away every cell and the reader's text selection with them. Recomputed one
    /// pass later, the arrival is a `.grew` on its own and the fold is a `.shrank` on its own, and
    /// neither costs a reload. See `TranscriptListView`, where the recompute hangs off the row
    /// count.
    public struct Runs: Equatable, Sendable {
        public var runs: [Run]
        /// How many rows produced this, so a rescan can tell an append from a new session.
        public var scannedRows: Int
        /// Where the next scan starts, which is just past the last row that broke a run. Nothing
        /// before it can change: the runs below are closed, and a closed run is frozen.
        public var resumeIndex: Int

        public static let none = Runs(runs: [], scannedRows: 0, resumeIndex: 0)

        public init(runs: [Run], scannedRows: Int, resumeIndex: Int) {
            self.runs = runs
            self.scannedRows = scannedRows
            self.resumeIndex = resumeIndex
        }

        /// The run this row index belongs to, or nothing.
        ///
        /// A binary search rather than a scan, because the list asks it once per row of the window
        /// on every pass that assembles the entries.
        public func run(containing index: Int) -> Run? {
            var low = 0
            var high = runs.count
            while low < high {
                let middle = low + (high - low) / 2
                if runs[middle].rows.upperBound <= index {
                    low = middle + 1
                } else if index < runs[middle].rows.lowerBound {
                    high = middle
                } else {
                    return runs[middle]
                }
            }
            return nil
        }
    }

    /// The runs in a session, extending what was already known about it.
    ///
    /// Rows are appended and never reordered, so everything below `previous.resumeIndex` is
    /// settled and only the tail is rescanned. Handed a shorter list than last time, which is a
    /// session being replaced rather than grown, it starts again from nothing.
    public static func runs<Facts: RandomAccessCollection>(
        in facts: Facts, extending previous: Runs = .none
    ) -> Runs where Facts.Element == Fact, Facts.Index == Int {
        let count = facts.count
        var start = previous.resumeIndex
        var found: [Run] = []
        if count < previous.scannedRows || start > count {
            start = 0
        } else {
            found = previous.runs.filter { $0.rows.upperBound <= start }
        }

        // The run being built: where it began, which sequence number opened it, and which indent
        // level it is at. Nil between runs.
        var building: (start: Int, firstSeq: Int, nested: Bool)?
        var lastSeq = 0
        var lastIndex = 0
        var members = 0
        var failed = false
        var resume = start

        func close(broken: Bool) {
            defer {
                building = nil
                members = 0
                failed = false
            }
            guard let run = building, members >= leastRun else { return }
            found.append(Run(
                rows: run.start..<(lastIndex + 1),
                seqs: run.firstSeq...lastSeq,
                lastDrawnIndex: lastIndex,
                hiddenCount: members - 1,
                canFold: broken && !failed
            ))
        }

        for offset in start..<count {
            let fact = facts[facts.index(facts.startIndex, offsetBy: offset)]
            if fact.kind == .toolUse {
                // A change of indent is a new run rather than a longer one: a fold that swallowed
                // a subagent's rows into its parent's would be a line that lies about where they
                // happened.
                if let building, building.nested != fact.nested { close(broken: true) }
                if building == nil {
                    building = (start: offset, firstSeq: fact.seq, nested: fact.nested)
                }
                members += 1
                lastSeq = fact.seq
                lastIndex = offset
                failed = failed || fact.failed
                continue
            }
            // A row that draws nothing is not a row the reader can see, so it neither starts a run
            // nor ends one. See `TranscriptRowInk`.
            if fact.drawsNothing { continue }
            close(broken: true)
            resume = offset + 1
        }
        // Whatever is left at the end is still growing, so it is not closed and cannot fold. It is
        // emitted all the same, because the fold's own entry has to be in the list BEFORE the run
        // folds: an entry appearing in the middle of the list on the same pass that rows leave it
        // is exactly the `.rebuilt` this design is arranged to avoid.
        close(broken: false)

        return Runs(runs: found, scannedRows: count, resumeIndex: min(resume, count))
    }
}
