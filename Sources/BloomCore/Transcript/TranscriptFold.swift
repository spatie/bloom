import Foundation

/// A run of consecutive tool calls, folded down to the newest of them and a line saying how many
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
/// # It folds while the turn is running, and everything below is what that costs
///
/// The first spelling waited for a run to be closed by a following drawn row, on the argument that
/// rows arriving during a turn are what the reader is watching. The owner read it and asked for
/// the opposite: a run should fold as soon as it is long enough, so that a turn's log is one line
/// and the call happening now, rather than forty lines that push the answer off the screen.
///
/// That closing row was doing a second job nobody had noticed. It was also the moment every tool
/// result in the run had arrived, because the CLI writes a call, then its result, then the next
/// call. Folding earlier means a call can be hidden while it is still running, and a result
/// landing afterwards can say it failed. So the rule that a failure is never hidden would have had
/// to unfold a run under a reader who is watching it, which is a worse interruption than the one
/// folding on completion was avoiding.
///
/// **So what may be hidden is a prefix, and the prefix only ever grows.** Three rules, and between
/// them nothing this type does can ever reveal a row it had hidden:
///
/// 1. **Only a call whose result has arrived may be hidden.** What such a call says is final: the
///    result sets `is_error`, the refusal and the duration in one write, so a hidden call cannot
///    change its mind. The newest call is always shown, running or not, which is the point of the
///    whole feature; and a burst of parallel calls, which arrive together with no results yet, is
///    simply drawn until the results land.
/// 2. **A failed call closes the run.** It is therefore the last call in its run and the row that
///    stays on screen, and the calls after it start a run of their own. This is the rule that
///    changed when folding moved to arrival: "a run holding a failure does not fold" cannot
///    survive a failure arriving after the fold, whereas closing the run keeps the promise that
///    matters, which is that a failed command is never the thing hidden. It is VS Code's
///    `chat.tools.autoExpandFailures` with the run cut at the failure rather than abandoned.
/// 3. **The prefix stops at anything asked to be visible**, rather than the run refusing to fold.
///    A tool result the reader opened is a row they are reading, and a run that grew past it would
///    otherwise have to unfold. Stopping the prefix there leaves the fold exactly as it was and
///    draws the opened call beside the newest one.
///
/// The one thing something asked to be visible cannot be is worse than cosmetic: a scroll can only
/// find a row the table is drawing, so a search hit or an unread mark hidden inside a fold is not
/// a row somewhere off screen, it is a scroll that lands nowhere at all.
public enum TranscriptFold {
    /// The shortest run worth folding, counted in calls.
    ///
    /// A fold costs one line for its own header, so a run of N leaves N minus one on screen: at
    /// two it saves nothing whatsoever, at three it saves a single line in exchange for a control
    /// and a decision, and at four it halves the run. Three is also about as much as a reader
    /// takes in at a glance (read the file, change it, check it), which is a thought rather than a
    /// log. So four, which is three hidden and one shown.
    public static let leastRun = 4

    /// How many calls a group needs before its fold gets an entry in the list at all.
    ///
    /// **Deliberately less than `leastRun`, and that gap is load bearing.** The fold's line is an
    /// entry of its own, and an entry appearing in the middle of the list on the same pass that
    /// rows leave it is two edits `TranscriptEntryChange` can only answer `.rebuilt` to. In the
    /// list from the second call onwards, drawing nothing until there is something to say, the
    /// pass that folds a run is a removal and nothing else. A group of one can never fold whatever
    /// the threshold, and a single call between two paragraphs is the commonest shape in a
    /// transcript, so it is the one that is not given an entry.
    public static let leastGroup = 2

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
    /// holds. "Earlier" is doing work too: the rows still on screen are the END of the run, so the
    /// hidden ones are the ones above them.
    ///
    /// The same words whether the fold is open or shut. A disclosure label names what is behind
    /// it, which does not change when it is opened, and a row whose text swapped on every click
    /// would read as two different rows.
    public static func label(hiding count: Int) -> String {
        count == 1 ? "1 earlier tool call" : "\(count) earlier tool calls"
    }

    /// How many calls at the front of this run are hidden right now, or nought for a run that is
    /// not folded.
    ///
    /// **A prefix that only grows, which is the whole of why nothing unfolds under a reader.**
    /// Every term below moves in one direction only: results arrive and never un-arrive, calls are
    /// appended and never removed, and `revealed` only ever gains a row that is already on screen.
    /// So the answer for a given run never goes down, and the fold is a rehearsal of removals
    /// rather than a state that can flip.
    ///
    /// `revealed` is every sequence number something has asked to be visible: the tool results the
    /// reader has opened, and the row this session was opened on, which is a search hit or an
    /// unread mark. `drawn` is the window of rows the list is handing to the table, because the
    /// row a fold keeps on screen has to be a row that is being drawn.
    public static func hides(_ run: Run, revealed: Set<Int>, drawn: Range<Int>) -> Int {
        // Never the last call. The newest one is the row the fold exists to keep on screen, and
        // hiding it is the one way this feature can take away the thing it was asked for.
        var count = min(run.settled, run.calls.count - 1)
        // Cut short at the first call somebody is reading or being taken to, rather than refusing
        // to fold at all: refusing would unfold a run that had already folded.
        if !revealed.isEmpty,
           let stop = run.calls.prefix(count).firstIndex(where: { revealed.contains($0.seq) }) {
            count = stop
        }
        guard count >= leastRun - 1 else { return 0 }
        // The first call that stays has to be one the table is drawing. A fold whose only surviving
        // row falls outside the window is a line standing over nothing.
        guard drawn.contains(run.calls[count].index) else { return 0 }
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
        /// The row came from inside a subagent. A change of nesting breaks a run: two indent
        /// levels folded into one line would be a fold that lies about where its rows were.
        public var nested: Bool
        /// What `TranscriptRowInk` says, which is that most `system` rows draw no view at all.
        public var drawsNothing: Bool
        /// The call's result has arrived, so nothing it says can change again. False for every
        /// row that is not a call. See rule 1 in the header.
        ///
        /// `failed` implies this, and the scan enforces it rather than trusting the caller: the
        /// two are written in the same breath when a result lands, and a call that could fail
        /// after being hidden would be a fold that has to unfold.
        public var settled: Bool

        public init(
            seq: Int,
            kind: MessageKind,
            failed: Bool,
            nested: Bool,
            drawsNothing: Bool,
            settled: Bool = false
        ) {
            self.seq = seq
            self.kind = kind
            self.failed = failed
            self.nested = nested
            self.drawsNothing = drawsNothing
            self.settled = settled
        }
    }

    /// One call in a run: where its row is, and what it is called.
    ///
    /// The index answers "is this row hidden", which is a comparison against the first call that
    /// stays. The seq answers "is this the row somebody asked to see", which arrives as a set of
    /// sequence numbers from the view. Both are needed and neither can be derived from the other.
    public struct Call: Equatable, Sendable {
        public var index: Int
        public var seq: Int

        public init(index: Int, seq: Int) {
            self.index = index
            self.seq = seq
        }
    }

    /// One run, as the list needs it.
    public struct Run: Equatable, Sendable {
        /// The rows the run spans, as indices into the session's rows. Interior rows that draw
        /// nothing are inside it.
        public var rows: Range<Int>
        /// Every call in the run, in order.
        public var calls: [Call]
        /// How many calls from the front have their result in.
        ///
        /// A prefix rather than a count, because a gap in the middle would let a call whose result
        /// is still outstanding be hidden behind one that has landed. It stops at the first call
        /// that has not settled and it never goes backwards, which is what makes the fold monotone.
        public var settled: Int

        /// The fold's identity, which is the sequence number of the FIRST call in it.
        ///
        /// **The first rather than the last, and it is the whole reason a growing run is cheap.**
        /// The fold's own entry sits at the head of the run and is in the list from the moment the
        /// run reaches `leastGroup`, folded or not, so folding one removes rows after an entry
        /// that was already there and `TranscriptEntryChange` answers `.shrank`. Named by the last
        /// call instead, the entry would move every time a call arrived.
        public var firstSeq: Int { calls.first?.seq ?? 0 }

        public init(rows: Range<Int>, calls: [Call], settled: Int) {
            self.rows = rows
            self.calls = calls
            self.settled = settled
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
    ///
    /// **One shape is still a reload, and it is left in on purpose.** A group born past the
    /// threshold in a single pass, with every result already back, has no line in the list for the
    /// removal to hang off, so that pass is an insertion and a removal at once. Rule 1 is what
    /// makes it unreachable in practice: calls the CLI writes in a burst are parallel calls, and
    /// parallel calls arrive with no results at all, so they are drawn until the results land and
    /// the line is in the list by then. What is left needs the main thread stalled across a run
    /// boundary while four calls and four results buffer up, and it costs one `reloadData`.
    /// Defending it would mean carrying "was this run already listed" from scan to scan, which is
    /// history this type deliberately does not keep: everything here is a function of the rows as
    /// they are now, plus an index saying where a rescan may start.
    public struct Runs: Equatable, Sendable {
        public var runs: [Run]
        /// How many rows produced this, so a rescan can tell an append from a new session.
        public var scannedRows: Int
        /// Where the next scan starts, which is just past the last row that BROKE a run.
        ///
        /// Not past the last run. A run cut short by a failure or by a change of indent is still
        /// open to being cut somewhere else when a result lands, and a run with a call still
        /// running has a settled prefix that is going to grow. Only a row the reader can see,
        /// sitting between two runs, settles everything above it: the CLI writes it after every
        /// result in the run above has come back.
        public var resumeIndex: Int

        public static let none = Runs(runs: [], scannedRows: 0, resumeIndex: 0)

        public init(runs: [Run], scannedRows: Int, resumeIndex: Int) {
            self.runs = runs
            self.scannedRows = scannedRows
            self.resumeIndex = resumeIndex
        }

        /// Where in `runs` the run holding this row index is, or nothing.
        ///
        /// A binary search rather than a scan, because the list asks it once per row of the window
        /// on every pass that assembles the entries.
        ///
        /// **An index rather than the run itself, and that is the per-row cost rather than a
        /// style.** A `Run` carries an array, so handing one back is a retain and a release on
        /// every row of the window on every pass. The caller takes the value once per RUN, where
        /// it needs the calls, and asks this question with nothing to release.
        public func runIndex(containing index: Int) -> Int? {
            var low = 0
            var high = runs.count
            while low < high {
                let middle = low + (high - low) / 2
                if runs[middle].rows.upperBound <= index {
                    low = middle + 1
                } else if index < runs[middle].rows.lowerBound {
                    high = middle
                } else {
                    return middle
                }
            }
            return nil
        }

        /// The run this row index belongs to, or nothing.
        public func run(containing index: Int) -> Run? {
            runIndex(containing: index).map { runs[$0] }
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

        // The group being built: where it began, which indent level it is at, the calls in it,
        // and how many of those from the front have their results in. Empty between groups.
        var groupStart = 0
        var groupNested = false
        var calls: [Call] = []
        var settled = 0
        var resume = start

        func close() {
            defer {
                calls = []
                settled = 0
            }
            guard calls.count >= leastGroup, let last = calls.last else { return }
            found.append(Run(
                rows: groupStart..<(last.index + 1), calls: calls, settled: settled
            ))
        }

        for offset in start..<count {
            let fact = facts[facts.index(facts.startIndex, offsetBy: offset)]
            if fact.kind == .toolUse {
                // A change of indent is a new run rather than a longer one: a fold that swallowed
                // a subagent's rows into its parent's would be a line that lies about where they
                // happened.
                if !calls.isEmpty, groupNested != fact.nested { close() }
                if calls.isEmpty {
                    groupStart = offset
                    groupNested = fact.nested
                }
                // The prefix stops at the first call still waiting, so a later call settling
                // cannot reach over one that has not.
                //
                // **A failure counts as settled here whatever the caller said, and that is the
                // invariant the monotonicity rests on.** A result writes `is_error`, the refusal
                // and the payload in one go, so a call cannot have failed without having settled;
                // read the other way round, a call that is hidden has already settled and can
                // therefore never turn into a failure afterwards. Spelled out rather than trusted,
                // because a caller that let the two come apart would make a fold unfold.
                if fact.settled || fact.failed, settled == calls.count { settled += 1 }
                calls.append(Call(index: offset, seq: fact.seq))
                // A failure closes the run around itself, so it is the last call and therefore the
                // one that stays on screen. See rule 2 in the header. `resume` is deliberately not
                // advanced: the flag arrives with a result rather than with the row, so this cut
                // has to be able to move when the next rescan reads it.
                if fact.failed { close() }
                continue
            }
            // A row that draws nothing is not a row the reader can see, so it neither starts a run
            // nor ends one. See `TranscriptRowInk`.
            if fact.drawsNothing { continue }
            close()
            resume = offset + 1
        }
        // Whatever is left at the end is a run that is still growing, and it is emitted exactly
        // like any other: folding while the turn runs is the point, and the entry has to be in the
        // list before it folds.
        close()

        return Runs(runs: found, scannedRows: count, resumeIndex: min(resume, count))
    }
}
