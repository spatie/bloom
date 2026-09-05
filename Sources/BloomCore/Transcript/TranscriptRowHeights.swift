import Foundation

/// How tall each row of a transcript is, remembered so that a table can be told without measuring
/// the same row twice.
///
/// **This exists because a table has to be TOLD every height and SwiftUI will only say what a row
/// is once it has laid it out.** So a row is measured off screen, once, and the answer is kept.
/// The bookkeeping around that is the whole of this type, and it is here rather than in the view
/// for the reason the three-target split exists: what is cached, what invalidates it, and which
/// of two disagreeing answers wins are decisions, and a decision taken inside a view is a decision
/// nothing can test.
///
/// ## The key is the content, and the width and the scale are the cache's
///
/// The content is a `TranscriptContentKey`, which is a hash rather than the string it used to be:
/// see that type for what building four hundred of those strings on every pass cost.
///
/// A row's height depends on four things: what it draws, how wide it is drawn, the text size it is
/// drawn at, and how far apart its lines are set. The obvious spelling folds all four into one
/// key, which is what the spike did, and it is wrong in a way that only shows up after a while:
/// the pane is resized all day, so the cache accumulates one entry per row per width it has ever
/// been, none of which will ever be asked for again. Width, scale and leading are properties of
/// the whole cache instead, held once, and changing any of them empties it. That is also the
/// truthful shape, because there is never more than one width in play.
///
/// ## Nothing is measured up front
///
/// A row nobody has measured is not a question the table can be made to wait for: it is told
/// `estimate`, drawn if the reader ever looks at it, and corrected by `note` the moment it is.
/// **This is what makes arriving at a conversation cost one screen rather than a window of rows.**
/// Building the four hundred `NSHostingView`s a window used to open with was the whole of "opening
/// a workspace or a tab with a chat in it is slow", and none of them was for a row anybody saw.
///
/// The estimate is the middle of what HAS been measured here, which after one screen of a real
/// conversation is a better number than any constant, and `assumedRowHeight` until then. Never
/// more than `mostEstimated`, because a guess that fills the screen on its own is worse than no
/// rows at all: see `Running.middle` for the conversation that was drawn 885,212 points long. What
/// keeps this honest is that no placement is ever resolved against an estimate: the caller
/// measures the screen it is about to show, exactly, before it shows it.
///
/// **A row that is going to draw nothing is not estimated at all, it is answered.** Most of a
/// session is stream events with no view in them, and a mean is the worst possible answer for one:
/// too tall by the whole mean, three or four times between every pair of tool calls. Worse, each
/// of them is then corrected the moment it is drawn, and correcting a row near the top of a long
/// list moves every row below it. `TranscriptRowInk` is how a caller knows before anything is
/// drawn; `assumed(for:shape:drawsNothing:)` is where the answer goes in.
///
/// ## It outlives the conversation it was filled for
///
/// A pane is pointed at one conversation after another, and the heights of the one being left are
/// exactly what makes coming back to it free, so nothing here is emptied by a switch. Two things
/// follow. Every key has to be unique across sessions, which stored rows get from a row id and
/// which the transcript's two synthetic entries have to be given (see `TranscriptListView`). And
/// the cache has to have a bound, which is `mostRows`.
///
/// ## The measurements outlive the conversation. The ESTIMATE must not
///
/// **This is the reader's report of "switching workspaces sometimes leaves gigantic gaps", and
/// it was measured rather than argued.** A measured height belongs to a row, so it is worth
/// keeping for ever. The estimate belongs to a CONVERSATION: it is the mean of what has been
/// measured, and it is what every row nobody has looked at yet is drawn at. A pane that had been
/// reading prose settled it at 400, and every unmeasured row of the tool-heavy workspace arriving
/// next was then laid out at 400 against a true 24. On the fifteen inked rows of one screen that
/// is 5,640 points of blank, which is eight screens of it, and it is exactly the picture the
/// report came with: a message, a fold, a pane of nothing, and two lines jammed against the
/// composer.
///
/// Worse, it could not be taken again. `resettleDrift` will only re-form the number once the
/// sample has DOUBLED, and the sample was the two thousand rows of the conversation being left, so
/// four hundred measured rows of the one arriving moved it by nothing at all. The number a
/// workspace switch handed you was permanent for the visit.
///
/// So `showing(_:)` says which conversation the pane is pointed at, and a change of it starts the
/// estimate again while keeping every measured height. What the sample is formed from is the rows
/// measured since, which is `sampled`.
///
/// ## And ONE estimate cannot serve a conversation either
///
/// **That fix was necessary and it was not sufficient, which is the reader's second report: still
/// white gaps between output when he scrolls UP.** Scrolling back is the window growing at the
/// TOP, so the rows arriving are rows nobody has measured, and the number they are drawn at was
/// settled from the screen the pane ARRIVED on, which is the live end: the newest answer, which is
/// the longest prose in the session, next to a turn footer. A screen of tool calls and folded runs
/// from an hour ago is then a screen of one line rows each given a paragraph's height, and a cell
/// draws from its top down, so the difference is blank under every one of them.
///
/// A conversation does not have one row height. It has a handful of clusters, and which cluster a
/// row is in is known from the row before anything is drawn: see `TranscriptRowShape`. So the
/// number is kept per shape as well as over the whole conversation, and an unmeasured row is told
/// its own shape's number as soon as there is one. `settleShapeAfter` is how much evidence "one"
/// takes, and it is deliberately small, because rows of one shape cluster: three folds say more
/// about the fourth fold than twenty-four paragraphs do.
///
/// What this cannot do is remove the gap. A row nobody has measured is a guess whatever it is
/// grouped with, and prose is genuinely unpredictable: two answers in the same conversation differ
/// by a factor of ten. It narrows the guess to the spread WITHIN a kind of row from the spread
/// ACROSS all of them, and for the shapes a reader meets most of when scrolling back, which are
/// the near-constant ones, that is most of the way to exact.
///
/// ## A live resize does not remeasure, on purpose
///
/// Every cached height was taken at a width that no longer holds, so all of them are wrong the
/// moment a divider moves, and taking them again is a whole SwiftUI layout per row per frame of
/// the drag. So the caller does not: it holds the transcript at the width it was and lets go once,
/// when the hand does. `rewidth(to:)` is where that lands, and it keeps the old numbers as
/// estimates rather than emptying the cache, because emptying it is the four second stall the hold
/// exists to remove. See `TranscriptPaneHold`.
///
/// ## Nought is a real height
///
/// A stored row that draws nothing is ordinary: an assistant block with no text, a tool result
/// whose call is already on the row above it, a system row that is not an init. In a `LazyVStack`
/// every one of those is an `EmptyView` and takes no space at all. Treating a measurement of
/// nothing as a measurement that failed, and substituting one row height for it, is what put
/// several hundred points of blank between the rows of a real conversation: five empty rows in
/// succession under `Session started`, then three, then three more above a turn footer. So
/// nothing is stored and returned exactly as it arrives.
public struct TranscriptRowHeights: Equatable, Sendable {
    /// The width, text size and line height every height in this cache was taken at.
    ///
    /// One measure for the whole cache rather than part of each key: see the header. Nil until a
    /// width has arrived at all, which is the state a table is in for its first pass, before it
    /// has been laid out and while it still has no width to lay a row out against.
    public struct Measure: Equatable, Sendable {
        public var width: Double
        public var scale: Double
        /// The prose line height the rows were laid out at, as `ChatLineHeight.ratio` states it.
        ///
        /// Here because the owner made the line height a setting, and a setting that moves every
        /// measured row while the cache holds the old numbers is rows drawn on top of each other.
        /// It is the ratio rather than the step, so nothing in the core has to know that a step is
        /// what a person picks.
        public var leading: Double

        public init(width: Double, scale: Double, leading: Double) {
            self.width = width
            self.scale = scale
            self.leading = leading
        }

        /// Whether two measures are the same one.
        func matches(_ other: Measure) -> Bool {
            TranscriptRowHeights.isSameWidth(width, other.width)
                && scale == other.scale
                && leading == other.leading
        }
    }

    /// Whether two widths are the same width.
    ///
    /// Half a point, because a scroll view's own arithmetic lands on fractions and a row laid out
    /// at 831.5 points is the same row as one laid out at 831.75. Anything coarser and a real drag
    /// would fail to invalidate; anything finer and a rounding error would empty the cache for
    /// nothing. Public because `TranscriptPaneHold` asks the same question of a pane's frame and
    /// there is one answer to it.
    public static func isSameWidth(_ one: Double, _ other: Double) -> Bool {
        abs(one - other) <= 0.5
    }

    /// **Whether a height taken at this width is evidence about the width the cache is for.**
    ///
    /// A height is a fact about a width. `reset` and `rewidth` have both refused a width they
    /// cannot use since the day they were written, and `narrowest`'s own comment says why: a table
    /// that has not been laid out reports a width of nought or one, and a row measured against
    /// that is a row one point tall. That guard was on the measuring path and missing from the
    /// REPORTING one, which is the authoritative half: `note`'s own comment says a report from a
    /// row that has actually been drawn outranks anything measured off screen.
    ///
    /// **What that cost, measured on the owner's own conversation.** Two rows reported heights
    /// from a layout pass during a composer drag and then reported the truth again afterwards:
    /// a three line paragraph whose height is 54 points reported 1,972, and a user message whose
    /// height is 444 reported 10,806. Both ratios are a row wrapped into a column about fifteen
    /// points wide. The 10,806 settled the `message` shape's estimate at 6,025 points, which was
    /// then handed to every unmeasured row of that shape in a 2,650 row table, and the document
    /// came out 885,212 points long against a true 172,208. That is the blank transcript the owner
    /// filmed: a viewport inside rows drawn thousands of points tall.
    ///
    /// **What is known and what is not.** That it happened is measured, from four probe runs where
    /// exactly one shows the two spikes and three do not. WHY a cell was laid out at a fraction of
    /// its width for a pass is not known, and this rule does not answer it: it stops the app
    /// believing the answer, which is a different thing from understanding the question.
    /// `TranscriptHoldCensus.reportedAtAnotherWidth` counts them so the thread can be picked up.
    ///
    /// **Refusing costs nothing**, which is what makes this safe rather than a trade. A row whose
    /// report is refused stays unmeasured for another pass and is drawn from its estimate, which
    /// is the state every row in a conversation starts in; it is laid out again at the right width
    /// on the next pass and reports again, and that is the same mechanism that repairs every wrong
    /// height in this file today. What it cannot do is leave a row unmeasured for ever: the width
    /// the cache is for comes from `columnWidth`, which is the table's own width, and a cell is
    /// laid out inside that table, so the two agree except across the pass that changes them.
    public static func isEvidence(measuredAt width: Double, forCacheAt cacheWidth: Double?) -> Bool {
        guard let cacheWidth else { return false }
        return isSameWidth(cacheWidth, width)
    }

    /// The most rows remembered before the cache is emptied and started again.
    ///
    /// **A pane keeps the heights of every conversation it has drawn**, which is what makes
    /// arriving back at one free, and one pane visits a great many in a day. At about 150 bytes a
    /// row this is a few megabytes, which is the point at which it stops being a cache and starts
    /// being a leak.
    ///
    /// Emptied rather than trimmed. There is no recency here to evict by, and adding some to
    /// answer a question that arises once a day would be bookkeeping on every note: the honest
    /// cost of hitting this is one conversation measured again.
    public static let mostRows = 20_000

    /// What a row is worth before anything at all has been measured here.
    ///
    /// The one number in this file nothing measured, and it is only ever the answer for the first
    /// screen of the first conversation a pane draws: one measured row replaces it with the mean
    /// below. A tool row is about thirty points and a paragraph of prose several hundred, so this
    /// is deliberately nearer the short end. Guessing high would open every conversation with a
    /// document several times the height of its content and a scroller to match.
    public static let assumedRowHeight: Double = 64

    /// **The most a row nobody has looked at may be told it is.**
    ///
    /// A ceiling on the GUESS and never on a measurement: a row that really is ten thousand points
    /// tall is told ten thousand the moment anything measures it. This is only about what the
    /// table is handed for the rows it has not asked about, which on a long conversation is nearly
    /// all of them.
    ///
    /// **The asymmetry is the whole argument, and it is not symmetric at all.** Guessing low costs
    /// a row that grows when it is drawn, which is the design already: every height is corrected
    /// by `note` the moment the row is laid out, and the document gets longer under rows nobody is
    /// looking at. Guessing high costs a screenful of white with nothing in it, which a reader
    /// cannot tell from a broken app, and which they cannot get out of by scrolling because the
    /// next screen is more of the same row.
    ///
    /// **The number is from the data rather than from taste.** Two `ComposerProbe` runs over the
    /// owner's own conversation produced six settled shape estimates that were plausible (24,
    /// 37.7, 303.2, 346.8, 361.3 and 417.7 points) and two that were the bug (790.7, and 6,025.3
    /// for four rows at once). 450 is above every one of the first group and below both of the
    /// second, and it is about one transcript pane at the height a dragged composer leaves it: the
    /// probe's viewport was 446 points at the end of its drag. So the rule this states is that no
    /// row nobody has looked at may fill the screen on its own.
    ///
    /// **No run has exercised it, and a later reader should not think it has been validated.** On
    /// the probe run that followed the median landing, the largest number handed to an unmeasured
    /// row was 154 points, so this never fired: the median alone did the work and this stood
    /// behind it. What would exercise it is a conversation whose rows genuinely are tall, and
    /// there is no such run. 450 is a reasoned ceiling rather than a measured one, and what would
    /// move it is a session where a shape's honest middle is above it.
    public static let mostEstimated: Double = 450

    /// How many drawn rows it takes before the estimate stops moving.
    ///
    /// **A row's height and the document's total are two questions, and the second one needs the
    /// answer to hold still.** A table caches every height it is told and re-asks only when it is
    /// told to, so the total is the sum of what each row was told when it was last asked. A
    /// running mean that drifts turns every wholesale re-ask, which is the history landing and any
    /// remeasure, into one jump of `unmeasured x drift`: on a 2,981 row conversation that was a
    /// single move of 32,218 points, the height of the whole document.
    ///
    /// So the mean is taken from the first rows drawn here and then held. About a screenful,
    /// because that is what a pane measures on arrival before it shows anything, and because the
    /// point is to stop moving rather than to be perfect: a frozen number that is wrong by a fifth
    /// leaves every unmeasured row wrong by a fifth and the document still, and each of those rows
    /// is put right the moment it is drawn, which is the whole design.
    ///
    /// Held, but not for ever: see `resettleDrift` for the one screenful this settles from being
    /// the least representative one in the session.
    public static let settleAfter = 24

    /// How far out the settled estimate has to be before it is worth taking again.
    ///
    /// **Freezing was right and the number it froze on was formed too early.** A pane arrives at
    /// the live end and measures that screen, so the sample the estimate settles from is the tail
    /// of the conversation: the newest answer, which is the longest prose in the session, next to
    /// a footer. Measured on a 2,981 row conversation, the document it produced swung to 54,353
    /// points against a true 35,290, half again too tall, and stayed there because nothing could
    /// take the number again.
    ///
    /// So it can be taken again, and both halves of that are load bearing. A quarter out, because
    /// a settled number that is nearly right must not move: the whole point of freezing is that a
    /// wholesale re-ask cashes in the drift since the last one. And not until the sample has
    /// DOUBLED, so that a mean hovering near the threshold cannot re-settle twice for the same
    /// rows, and so the number of times this can fire over a session is a handful rather than a
    /// count of the rows in it.
    public static let resettleDrift = 0.25

    /// How many drawn rows OF ONE SHAPE it takes before that shape answers for itself.
    ///
    /// **Three, and the smallness is the whole point of it.** `settleAfter` is a screenful,
    /// because a mean over every kind of row at once needs a screenful before it means anything.
    /// A shape is a group of rows whose heights cluster, so it does not: a fold's line is the same
    /// height every time it is drawn, a turn footer nearly so, and a collapsed tool card within a
    /// line or two. Three of them says more about the fourth than a screenful of another shape
    /// does, which is the number those rows are drawn at today.
    ///
    /// And it has to be small to arrive in time. The rows a reader scrolling back meets are the
    /// ones the arrival screen saw least of: one screen at the live end holds a great deal of the
    /// newest answer and perhaps three folds. A threshold of a screenful per shape would leave
    /// every shape but prose falling back to the conversation's own mean, which is the number that
    /// left the gaps.
    ///
    /// Small, and then held under the same rule the whole-conversation number is held under: see
    /// `settleIfItIsTime`. An unlucky three is not permanent, and the sample has to double before
    /// it can be taken again, so a shape re-forms its number a handful of times over a session
    /// rather than on every row.
    public static let settleShapeAfter = 3

    /// Whether a row is the height it drew at.
    ///
    /// The same half point `note` files a measurement under, so the check that a drawn row is the
    /// height the table gives it cannot disagree with the cache about what counts as a change.
    /// See `TranscriptTable.Coordinator.checkCorrected`.
    public static func isSameHeight(_ one: Double, _ other: Double) -> Bool {
        abs(one - other) <= 0.5
    }

    /// The narrowest width worth measuring a row at.
    ///
    /// A table that has not been laid out yet reports a width of nought or one, and a row measured
    /// against that is a row one point tall. A table told one point per row is a transcript that
    /// is not there.
    public static let narrowest: Double = 1

    /// The width, text size and line height every height in here was taken at, or nothing before a
    /// width has arrived. What a caller measures a fresh row against, so that it cannot measure at
    /// one width and file the answer under another.
    public private(set) var measure: Measure?
    /// The conversation the pane is drawing, and therefore the one the estimate is about. Nothing
    /// before the first `showing(_:)`, which is a pane that has not been pointed anywhere yet.
    public private(set) var conversation: SessionID?
    private var heights: [TranscriptContentKey: Double] = [:]
    /// The keys whose height was taken at a width that no longer holds. See `rewidth`.
    private var stale: Set<TranscriptContentKey> = []
    /// **The rows the estimate is formed from: the ones measured since the pane was pointed at
    /// this conversation.**
    ///
    /// A record of each row rather than a count, because `note` has to know whether a number
    /// arriving is a row joining the sample or a row already in it saying itself again, and the
    /// two are arithmetic in opposite directions. `heights` cannot answer that question after
    /// `showing(_:)`: a key it already knows can be a row of the conversation being arrived at,
    /// measured on the last visit, and subtracting a contribution that was never added is how a
    /// mean goes negative.
    ///
    /// What it records is the shape, where it used to be a set with no value at all, because a row
    /// coming out again has to come out of the mean it went into and this is the only thing that
    /// says which one that was.
    private var sampled: [TranscriptContentKey: TranscriptRowShape] = [:]
    /// The mean over every measured row of this conversation, whatever shape it was. What a row
    /// whose own shape has not been seen enough of is still told.
    private var overall = Running()
    /// The same arithmetic again, kept per shape. See the header, and `TranscriptRowShape`.
    private var shapes: [TranscriptRowShape: Running] = [:]

    /// One running mean, and the settle over it.
    ///
    /// Its own type because there are now several of these, one for the conversation and one per
    /// shape, and they are the same three decisions each time: what the mean is, when it stops
    /// moving, and when it is worth taking again.
    private struct Running: Equatable, Sendable {
        /// How many of the sampled rows are more than nothing, which is what a rank is taken over.
        /// See `middle` for why the rows that drew nothing are not in it.
        var inked = 0
        /// **The sample, as a count per height, which is what makes a median affordable here.**
        ///
        /// A tally rather than a list, and the difference is what `absorb(_:replacing:)` needs: a
        /// row that reports again has to come out of the sample it went into exactly, and a list
        /// of recent values could not do that for the streaming tail, which reports on every frame
        /// of a turn.
        ///
        /// Keyed on the height itself rather than on a band of them, because `note` has already
        /// rounded every measurement up to a whole point: the key is what it stores, so the median
        /// is the true one rather than a bucket's middle, and there is no width to justify. What
        /// bounds this is the number of DISTINCT heights in a conversation, which is a few hundred
        /// where the rows are tens of thousands.
        var counts: [Int: Int] = [:]
        /// The estimate once it has stopped moving, or nothing while it is still being formed. See
        /// `settleAfter`, which carries what a drifting one costs.
        var settled: Double?
        /// How many drawn rows the settled number was formed from, so it is only taken again once
        /// there are twice as many. See `resettleDrift`.
        var settledFrom = 0

        /// What this says a row is worth, or nothing if it has nothing to say yet.
        var estimate: Double? {
            if let settled { return settled }
            return middle
        }

        /// **The median of the sample, and it was a mean.**
        ///
        /// The old argument for the mean is worth keeping and it was a cost one: the sum is held
        /// as it is written, so asking is free, where a median would mean keeping the numbers
        /// sorted. That is true, it lost to a correctness argument measured on the owner's own
        /// conversation with `ComposerProbe`, and the cost turned out to be a tally of a few
        /// hundred distinct heights sorted a handful of times a session. See `counts`.
        ///
        /// **A transcript's row heights are not a distribution a mean describes.** Of 408 rows in
        /// one band, 26 had ever been measured at more than nothing; their mean was 651 points and
        /// their largest was 10,806, against a typical row of a few dozen. `settleShapeAfter` is
        /// three, so three samples settle a shape's number for every unmeasured row of it, and one
        /// long answer in a sample of five is what handed 54 unmeasured rows 347 points each and,
        /// before it re-settled, four rows 6,025 points each. Fourteen screens, for content nobody
        /// had looked at. The document came out 885,212 points long against a true 172,208, and a
        /// viewport inside rows drawn like that is the blank transcript the owner filmed.
        ///
        /// A median has none of that: one row of ten thousand points moves it by one rank. And it
        /// errs SHORT on a distribution with a tail, which is the direction that costs nothing:
        /// see `mostEstimated`.
        ///
        /// The lower median for an even sample, for the same reason.
        var middle: Double? {
            guard inked > 0 else { return nil }
            let wanted = (inked - 1) / 2
            var seen = 0
            for height in counts.keys.sorted() {
                seen += counts[height] ?? 0
                if seen > wanted { return Double(height) }
            }
            return nil
        }

        /// Takes a measurement in, and the one it replaces out.
        ///
        /// The second and later times a row says itself, which is the streaming tail on every
        /// frame of a turn and any row corrected after it was drawn, what it said before comes out
        /// again: the sample is one contribution per row, not one per report.
        mutating func absorb(_ height: Double, replacing previous: Double, settlingAfter: Int) {
            remove(previous)
            add(height)
            settleIfItIsTime(settlingAfter: settlingAfter)
        }

        /// Takes a measurement back out, for a row that is moving to another shape's sample.
        mutating func release(_ height: Double) {
            remove(height)
        }

        private mutating func add(_ height: Double) {
            guard height > 0 else { return }
            counts[Int(height), default: 0] += 1
            inked += 1
        }

        private mutating func remove(_ height: Double) {
            guard height > 0 else { return }
            let key = Int(height)
            guard let count = counts[key] else { return }
            if count <= 1 { counts[key] = nil } else { counts[key] = count - 1 }
            inked -= 1
        }

        /// Takes the estimate, if there is enough to take it from and it is worth taking again.
        ///
        /// Once at `settlingAfter`, and after that only when the sample has doubled AND the
        /// running median disagrees with what is held by more than `resettleDrift`. Both of those,
        /// so that a good first sample settles the number for the whole session and a bad one is
        /// not permanent.
        private mutating func settleIfItIsTime(settlingAfter: Int) {
            guard inked >= settlingAfter, let running = middle else { return }
            guard let settled else { return take(running) }
            guard inked >= settledFrom * 2 else { return }
            guard abs(running - settled) > settled * TranscriptRowHeights.resettleDrift else {
                return
            }
            take(running)
        }

        private mutating func take(_ estimate: Double) {
            settled = estimate
            settledFrom = inked
        }
    }

    public init() {}

    /// Whether there is a width worth measuring against yet.
    public var isReady: Bool { measure != nil }

    /// How many rows are remembered. For tests and for a probe; nothing decides anything on it.
    public var count: Int { heights.count }

    /// Declares the width, text size and line height the cache is now for, and says whether that
    /// emptied it.
    ///
    /// True means every height the caller holds is now unknown and the rows have to be renoted to
    /// the table. False means nothing moved and there is nothing to do, which is the answer on
    /// almost every pass and is why this is cheap to ask.
    ///
    /// A width narrower than `narrowest` is not an answer and is refused: it leaves the cache
    /// exactly as it was rather than emptying it against a number no row will be drawn at.
    @discardableResult
    public mutating func reset(width: Double, scale: Double, leading: Double) -> Bool {
        guard width > Self.narrowest else { return false }
        let wanted = Measure(width: width, scale: scale, leading: leading)
        if let measure, measure.matches(wanted) { return false }
        measure = wanted
        heights.removeAll()
        stale.removeAll()
        sampled.removeAll()
        overall = Running()
        shapes.removeAll()
        return true
    }

    /// **Declares which conversation the pane is drawing, and says whether that started the
    /// estimate again.**
    ///
    /// Keeps every measured height, because a height belongs to a row and coming back to a
    /// conversation that has been read once is meant to be free. Starts the estimate again,
    /// because the mean of the rows of the conversation being left is not a claim about the one
    /// arriving: see the header for the eight screens of blank that produced, and for why nothing
    /// could take the number again afterwards.
    ///
    /// Idempotent, so a caller may say it on every pass. Nothing happens until the answer changes.
    @discardableResult
    public mutating func showing(_ conversation: SessionID) -> Bool {
        guard self.conversation != conversation else { return false }
        self.conversation = conversation
        sampled.removeAll()
        overall = Running()
        shapes.removeAll()
        return true
    }

    /// Declares a new width and keeps every height as an ESTIMATE of what it will be at it.
    ///
    /// **`reset` is right and it costs four seconds.** Emptying the cache means a fresh
    /// `NSHostingView` for every row in the session before the table can be told anything, which
    /// on an 1,855 row conversation is the stall a resize was reported for. So a resize does this
    /// instead: the width moves, the numbers stay, and each one is marked as owed a measurement.
    /// The caller measures what the reader can see exactly and lets the rest be corrected when
    /// they are drawn, which `note` already does and outranks anything measured off screen.
    ///
    /// It is a better estimate than it sounds. Most rows in a transcript are tool headers, footers
    /// and notices whose height does not depend on the width at all, so for most of the list the
    /// old number is not a guess, it is the answer.
    ///
    /// Only ever a width: a text size or line height change goes through `reset`, because a
    /// paragraph set at another size, or led differently, is not an estimate of anything.
    @discardableResult
    public mutating func rewidth(to width: Double) -> Bool {
        guard let current = measure, width > Self.narrowest else { return false }
        guard !Self.isSameWidth(current.width, width) else { return false }
        measure = Measure(width: width, scale: current.scale, leading: current.leading)
        stale = Set(heights.keys)
        return true
    }

    /// Whether this height is owed a measurement at the width the cache is now for.
    public func isStale(_ contentKey: TranscriptContentKey) -> Bool { stale.contains(contentKey) }

    /// How many heights are still estimates. For a probe: it is the count of rows a resize did
    /// NOT have to measure, which is the whole of what the hold buys.
    public var staleCount: Int { stale.count }

    /// **Whether this content is owed a measurement, and a hit in here is not always the answer.**
    ///
    /// A stored row's key is hashed from everything that can change what it draws, so a number
    /// filed under one is the answer until the key moves and this can say no. Four of the entries
    /// in a transcript are not stored rows, and each of them redraws itself from its own
    /// observation inside the cell it is in: the streaming tail, the setup log, the bubble on its
    /// way out and the delivery at the head of the queue. Their keys carry the session and nothing
    /// else that moves, so a hit for one of those is not what it draws, it is **what it happened to
    /// be the last time somebody looked**.
    ///
    /// The tail is the one that bites, and it is the reader's report: leave a workspace with a
    /// turn running and the last number taken from that tail is several hundred points; come back
    /// once the turn has finished and it draws nothing at all, under the same key, with the table
    /// still laying out the several hundred. That is a screen and a half of blank between the last
    /// turn's footer and the composer, and every mechanism that could put it right declines to.
    /// The caller's `measureExactly` skipped it because the cache knows it, the warming pass skips
    /// it on purpose, and the screen census cannot see it because the cache and the table agree
    /// about a number that is wrong in both.
    ///
    /// So the caller says which kind of entry it is holding and this says whether what is held is
    /// still evidence. See `TranscriptEntryID.redrawsItself`, which is the claim, and the census's
    /// `screenWrong`, which is the counter this shape is invisible to.
    public func needsMeasuring(_ contentKey: TranscriptContentKey, redrawsItself: Bool) -> Bool {
        redrawsItself || heights[contentKey] == nil || stale.contains(contentKey)
    }

    /// **Whether a screenful the reader has stopped on is worth putting right.**
    ///
    /// Two faults, one answer, and the second one is why this is not simply `wrong > 0`.
    ///
    /// `wrong` is the table and the cache disagreeing: a number was taken and the table was never
    /// told. `guessed` is a visible row the table is drawing at a height NOBODY has measured, and
    /// there the two agree perfectly about a number that is wrong in both, which is what makes it
    /// invisible to a disagreement count. That is the shape this file has now been wrong about
    /// twice: once as the streaming tail, where the cache held a stale number and the row was not
    /// even counted as a guess, and once as a fold's line, where the cache holds nothing at all.
    ///
    /// A fold's line is the case that forced this. Its content key carries the count in its words,
    /// so the key moves every time a call lands, and the row is one line tall in every one of
    /// those states. `HostedRow` reports through `onChange(of: proxy.size.height)`, so an entry
    /// whose key moves without its height moving never reports again after the first time, and the
    /// cache has nothing for the key the table is currently drawing. `assumed` then answers the
    /// running mean, which is `assumedRowHeight` at worst and a prose-heavy conversation's average
    /// at best, and what the reader sees is a one line row with most of a screen of nothing under
    /// it. The screen census counted it and nothing acted on the count.
    public static func needsRepair(guessed: Int, wrong: Int) -> Bool {
        guessed > 0 || wrong > 0
    }

    /// The remembered height of this content, or nothing if it has never been measured.
    public func height(for contentKey: TranscriptContentKey) -> Double? {
        heights[contentKey]
    }

    /// **Whether this row has been measured and turned out to draw nothing at all.**
    ///
    /// The question a table asks before building a view for a row. A row that drew nothing has no
    /// view worth building: under a table, every visible row costs an `NSHostingView` with its own
    /// SwiftUI graph, its own runloop observer and its own place in the layout, and a sixth of a
    /// millisecond of graph flush per row per frame is what a scroll is made of. Sixty per cent of
    /// a real session is such rows.
    ///
    /// **Measured, and not merely claimed, and the difference is the whole safety of it.**
    /// `TranscriptRowInk` says what a row is EXPECTED to draw, which is a guess used to answer a
    /// height before anybody has drawn it. This says what a row TURNED OUT to draw when it was
    /// drawn, so nothing is owed a correction and there is nothing left to learn by drawing it
    /// again. A row that gains content gets a new content key, misses here, and is built like any
    /// other row.
    ///
    /// Exactly nought rather than `isSameHeight`, because `note` rounds a height UP: a row that
    /// drew four tenths of a point is remembered as one and is not this.
    public func measuredNothing(_ contentKey: TranscriptContentKey) -> Bool {
        heights[contentKey] == 0
    }

    /// The middle of the rows of THIS conversation that have been measured here and drew
    /// something, or `assumedRowHeight` before there is one, and never more than `mostEstimated`.
    /// See `showing(_:)` for why the conversation is in that sentence.
    ///
    /// **It is the fallback rather than the answer now.** What an unmeasured row is actually told
    /// is `estimate(for:)`, which is this number only while the row's own kind has too little
    /// evidence to speak for itself.
    ///
    /// **It was a mean, and the argument for that was: kept as a running total, so asking is free,
    /// where a median would mean holding the numbers sorted for an answer that is corrected the
    /// moment the row is drawn.** That is a cost argument and it was true. It lost to a
    /// correctness one, measured rather than argued: a transcript's row heights run from nothing
    /// to ten thousand points, a mean over a handful of them is whatever the longest answer in the
    /// sample says, and the document it produced was 885,212 points long against a true 172,208.
    /// The cost the old argument was avoiding turned out to be a tally of the few hundred
    /// DISTINCT heights a conversation has, sorted a handful of times a session. See
    /// `Running.counts` and `Running.middle`, which carry the whole measurement.
    ///
    /// **The rows that drew nothing are deliberately not in it, and they used to be.** Most of a
    /// session is stream events that draw no view at all, so a mean over every measurement is a
    /// mean over thousands of noughts: it came out several times too small for the rows it is
    /// actually asked about. Those rows are answered by `assumed(for:shape:drawsNothing:)` without
    /// consulting this at all, so including them made the one number this still answers worse for
    /// no one's benefit.
    ///
    /// **And it stops moving once a screenful has been drawn.** See `settleAfter`: a running
    /// number is the right answer to "how tall is a row I know nothing about" and the wrong answer
    /// to "how tall is this document", and the second question is the one a reader feels.
    public var estimate: Double {
        min(Self.mostEstimated, overall.estimate ?? Self.assumedRowHeight)
    }

    /// **What an unmeasured row OF THIS SHAPE is worth**, which is the answer a reader scrolling
    /// back sees and the whole of the second fix.
    ///
    /// The shape's own number once `settleShapeAfter` rows of it have been drawn, and the
    /// conversation's until then, and neither of them above `mostEstimated`. Falling back rather
    /// than waiting, because a shape with no evidence yet is exactly the state the old single
    /// number was always in, so the fallback can only be as wrong as today and the shape can only
    /// be better: the two clusters a shape separates are separated by more than the noise inside
    /// either of them.
    ///
    /// See `TranscriptRowShape` for why a fold's line is the case that settles this: the same
    /// height every time it is drawn, one per turn all the way back through the conversation, and
    /// under one conversation-wide mean every one of them was given a paragraph's height.
    ///
    /// What it is worth, on a harness that walks a reader up a 350 row conversation one viewport
    /// at a time and adds up how far every unmeasured row is from its truth: 24,972 points of
    /// blank with one number, 9,387 with one per shape. It narrows the gap rather than removing
    /// it, and it cannot do better than that, because an answer nobody has drawn is a guess.
    public func estimate(for shape: TranscriptRowShape) -> Double {
        guard shape != .other, let running = shapes[shape],
              running.inked >= Self.settleShapeAfter, let answer = running.estimate
        else { return estimate }
        // Capped here as well as in `estimate`, because these are the two spellings of one
        // question and a caller must not be able to reach the unbounded one. See `mostEstimated`.
        return min(Self.mostEstimated, answer)
    }

    /// **The number to tell a table**: what is known, what is known to be nothing, or what is
    /// assumed.
    ///
    /// Never nil and never a measurement, so answering it for every row of a session costs a
    /// dictionary lookup each. See the header for why a table is answered rather than made to
    /// wait, and `TranscriptRowInk` for how a caller knows a row will draw nothing before anything
    /// has drawn it.
    public func assumed(
        for contentKey: TranscriptContentKey,
        shape: TranscriptRowShape = .other,
        drawsNothing: Bool = false
    ) -> Double {
        if let known = heights[contentKey] { return known }
        return drawsNothing ? 0 : estimate(for: shape)
    }

    /// Remembers a height, and says whether it is news.
    ///
    /// **A report from a row that has actually been drawn outranks anything measured off screen,
    /// so this overwrites rather than consults.** The number arriving is the ideal height of the
    /// same content, laid out by the same SwiftUI, at the width the row was really given. There is
    /// nothing better to know: a measurement that disagrees with what is on the screen is a wrong
    /// measurement, whichever of the two was taken first.
    ///
    /// It is also the only thing that can keep a streaming tail growing. Nothing watches the
    /// per-token buffers on purpose, so the only thing that knows the tail got taller is the tail.
    ///
    /// False for a height that has not moved by half a point, which is what keeps a row that
    /// reports its size on every layout pass from telling the table to relayout on every one.
    ///
    /// The shape is what the caller believes this row is, and it decides which running mean the
    /// measurement joins. It defaults to `.other` so that a caller with nothing to say does not
    /// have to invent something: an unclassified row still forms the conversation's own mean,
    /// which is what every row was told before there were shapes at all.
    @discardableResult
    public mutating func note(
        _ height: Double,
        for contentKey: TranscriptContentKey,
        shape: TranscriptRowShape = .other,
        measuredAt width: Double
    ) -> Bool {
        // **A height is a fact about a width**, and one taken at another width is not news about
        // this one. See `isEvidence`, which carries the two rows that reported 1,972 and 10,806
        // points from a pass that laid them out fifteen points wide.
        guard Self.isEvidence(measuredAt: width, forCacheAt: measure?.width) else { return false }
        // Before the news test below, so a row that turns out to be exactly as tall as it was at
        // the old width still stops being owed a measurement.
        stale.remove(contentKey)
        let rounded = Self.rounded(height)
        let known = heights[contentKey]
        // See `mostRows`. Asked before the insert, so the cache never holds more than it says.
        if heights.count >= Self.mostRows, known == nil { forget() }
        // **Before the news test, and that is the whole of what a returning reader gets.** A row
        // this pane measured on its last visit reports the same number again, which is no news to
        // the cache and is the only evidence this conversation has offered about how tall its rows
        // are. Counted here, the sample fills on a return as it does on a first visit; counted
        // after the test, a conversation the pane already knows would estimate from nothing.
        sample(rounded, for: contentKey, shape: shape)
        guard !Self.isSameHeight(known ?? -1, rounded) else { return false }
        heights[contentKey] = rounded
        return true
    }

    /// Puts a measurement into the two samples the estimates are formed from, once per row.
    ///
    /// Two, because there is the conversation's own mean and there is this row's shape's, and a
    /// row contributes to both. What it replaces comes out of both as well: see
    /// `Running.absorb(_:replacing:settlingAfter:)`.
    ///
    /// A row that arrives under a different shape from the one it was filed under is taken out of
    /// the old shape's sample first. It should not happen, because a shape is read off a row's
    /// kind and the kind is part of the content key, and it is handled anyway rather than left as
    /// a mean quietly counting a row twice.
    private mutating func sample(
        _ height: Double, for contentKey: TranscriptContentKey, shape: TranscriptRowShape
    ) {
        let before = sampled.updateValue(shape, forKey: contentKey)
        let previous = before == nil ? 0 : (heights[contentKey] ?? 0)
        if let before, before != shape { shapes[before, default: Running()].release(previous) }
        overall.absorb(height, replacing: previous, settlingAfter: Self.settleAfter)
        // **`.other` keeps no sample of its own, and that is what it means.** It is the shape for a
        // row nothing has classified, so the honest answer for one is the conversation's own mean:
        // a bucket for them would be a second whole-conversation mean settling on another schedule,
        // and the four entries in it are measured before anything else anyway.
        guard shape != .other else { return }
        shapes[shape, default: Running()].absorb(
            height,
            replacing: before == shape ? previous : 0,
            settlingAfter: Self.settleShapeAfter
        )
    }

    /// Rounded up to a whole point, and never below nothing.
    ///
    /// Up rather than to nearest, because a row given a fraction less than it asked for has its
    /// last line clipped, and half a point of air under a row is invisible. See the header for why
    /// nought is kept rather than treated as a failure.
    public static func rounded(_ height: Double) -> Double {
        max(0, height.rounded(.up))
    }

    /// Empties the cache without changing the width it is for. What a text size change, a line
    /// height change and a finished resize all come down to.
    public mutating func forget() {
        heights.removeAll()
        stale.removeAll()
        sampled.removeAll()
        overall = Running()
        shapes.removeAll()
    }
}
