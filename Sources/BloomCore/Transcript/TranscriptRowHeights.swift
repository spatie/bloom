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
/// A row's height depends on three things: what it draws, how wide it is drawn, and the text size
/// it is drawn at. The obvious spelling folds all three into one key, which is what the spike did,
/// and it is wrong in a way that only shows up after a while: the pane is resized all day, so the
/// cache accumulates one entry per row per width it has ever been, none of which will ever be
/// asked for again. Width and scale are properties of the whole cache instead, held once, and
/// changing either empties it. That is also the truthful shape, because there is never more than
/// one width in play.
///
/// ## Nothing is measured up front
///
/// A row nobody has measured is not a question the table can be made to wait for: it is told
/// `estimate`, drawn if the reader ever looks at it, and corrected by `note` the moment it is.
/// **This is what makes arriving at a conversation cost one screen rather than a window of rows.**
/// Building the four hundred `NSHostingView`s a window used to open with was the whole of "opening
/// a workspace or a tab with a chat in it is slow", and none of them was for a row anybody saw.
///
/// The estimate is the running mean of what HAS been measured here, which after one screen of a
/// real conversation is a better number than any constant, and `assumedRowHeight` until then. What
/// keeps this honest is that no placement is ever resolved against an estimate: the caller
/// measures the screen it is about to show, exactly, before it shows it.
///
/// **A row that is going to draw nothing is not estimated at all, it is answered.** Most of a
/// session is stream events with no view in them, and a mean is the worst possible answer for one:
/// too tall by the whole mean, three or four times between every pair of tool calls. Worse, each
/// of them is then corrected the moment it is drawn, and correcting a row near the top of a long
/// list moves every row below it. `TranscriptRowInk` is how a caller knows before anything is
/// drawn; `assumed(for:drawsNothing:)` is where the answer goes in.
///
/// ## It outlives the conversation it was filled for
///
/// A pane is pointed at one conversation after another, and the heights of the one being left are
/// exactly what makes coming back to it free, so nothing here is emptied by a switch. Two things
/// follow. Every key has to be unique across sessions, which stored rows get from a row id and
/// which the transcript's two synthetic entries have to be given (see `TranscriptListView`). And
/// the cache has to have a bound, which is `mostRows`.
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
    /// The width and text size every height in this cache was taken at.
    ///
    /// One measure for the whole cache rather than part of each key: see the header. Nil until a
    /// width has arrived at all, which is the state a table is in for its first pass, before it
    /// has been laid out and while it still has no width to lay a row out against.
    public struct Measure: Equatable, Sendable {
        public var width: Double
        public var scale: Double

        public init(width: Double, scale: Double) {
            self.width = width
            self.scale = scale
        }

        /// Whether two measures are the same one.
        func matches(_ other: Measure) -> Bool {
            TranscriptRowHeights.isSameWidth(width, other.width) && scale == other.scale
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

    /// The width and text size every height in here was taken at, or nothing before a width has
    /// arrived. What a caller measures a fresh row against, so that it cannot measure at one width
    /// and file the answer under another.
    public private(set) var measure: Measure?
    private var heights: [TranscriptContentKey: Double] = [:]
    /// The keys whose height was taken at a width that no longer holds. See `rewidth`.
    private var stale: Set<TranscriptContentKey> = []
    /// The sum of `heights`, kept in step on every write so the mean below costs nothing to ask.
    private var total: Double = 0
    /// How many of `heights` are more than nothing, which is what `estimate` divides by. See it
    /// for why a mean over the rows that drew nothing was the wrong number.
    private var inked = 0
    /// The estimate once it has stopped moving, or nothing while it is still being formed. See
    /// `settleAfter`, which carries what a drifting one costs.
    private var settled: Double?
    /// How many drawn rows the settled number was formed from, so it is only taken again once
    /// there are twice as many. See `resettleDrift`.
    private var settledFrom = 0

    public init() {}

    /// Whether there is a width worth measuring against yet.
    public var isReady: Bool { measure != nil }

    /// How many rows are remembered. For tests and for a probe; nothing decides anything on it.
    public var count: Int { heights.count }

    /// Declares the width and text size the cache is now for, and says whether that emptied it.
    ///
    /// True means every height the caller holds is now unknown and the rows have to be renoted to
    /// the table. False means nothing moved and there is nothing to do, which is the answer on
    /// almost every pass and is why this is cheap to ask.
    ///
    /// A width narrower than `narrowest` is not an answer and is refused: it leaves the cache
    /// exactly as it was rather than emptying it against a number no row will be drawn at.
    @discardableResult
    public mutating func reset(width: Double, scale: Double) -> Bool {
        guard width > Self.narrowest else { return false }
        let wanted = Measure(width: width, scale: scale)
        if let measure, measure.matches(wanted) { return false }
        measure = wanted
        heights.removeAll()
        stale.removeAll()
        total = 0
        inked = 0
        settled = nil
        settledFrom = 0
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
    /// Only ever a width: a text size change goes through `reset`, because a paragraph at another
    /// size is not an estimate of anything.
    @discardableResult
    public mutating func rewidth(to width: Double) -> Bool {
        guard let current = measure, width > Self.narrowest else { return false }
        guard !Self.isSameWidth(current.width, width) else { return false }
        measure = Measure(width: width, scale: current.scale)
        stale = Set(heights.keys)
        return true
    }

    /// Whether this height is owed a measurement at the width the cache is now for.
    public func isStale(_ contentKey: TranscriptContentKey) -> Bool { stale.contains(contentKey) }

    /// How many heights are still estimates. For a probe: it is the count of rows a resize did
    /// NOT have to measure, which is the whole of what the hold buys.
    public var staleCount: Int { stale.count }

    /// The remembered height of this content, or nothing if it has never been measured.
    public func height(for contentKey: TranscriptContentKey) -> Double? {
        heights[contentKey]
    }

    /// What an unmeasured row that draws SOMETHING is worth: the mean of the rows measured here
    /// that drew something, or `assumedRowHeight` before there is one.
    ///
    /// A mean rather than a median, because it is kept as a running total and a median would mean
    /// holding the numbers sorted for an answer that is corrected the moment the row is drawn.
    ///
    /// **The rows that drew nothing are deliberately not in it, and they used to be.** Most of a
    /// session is stream events that draw no view at all, so a mean over every measurement is a
    /// mean over thousands of noughts: it came out several times too small for the rows it is
    /// actually asked about. Those rows are answered by `assumed(for:drawsNothing:)` without
    /// consulting this at all, so including them made the one number this still answers worse for
    /// no one's benefit.
    ///
    /// **And it stops moving once a screenful has been drawn.** See `settleAfter`: a running mean
    /// is the right answer to "how tall is a row I know nothing about" and the wrong answer to
    /// "how tall is this document", and the second question is the one a reader feels.
    public var estimate: Double {
        if let settled { return settled }
        return inked == 0 ? Self.assumedRowHeight : total / Double(inked)
    }

    /// **The number to tell a table**: what is known, what is known to be nothing, or what is
    /// assumed.
    ///
    /// Never nil and never a measurement, so answering it for every row of a session costs a
    /// dictionary lookup each. See the header for why a table is answered rather than made to
    /// wait, and `TranscriptRowInk` for how a caller knows a row will draw nothing before anything
    /// has drawn it.
    public func assumed(for contentKey: TranscriptContentKey, drawsNothing: Bool = false) -> Double {
        if let known = heights[contentKey] { return known }
        return drawsNothing ? 0 : estimate
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
    @discardableResult
    public mutating func note(_ height: Double, for contentKey: TranscriptContentKey) -> Bool {
        guard measure != nil else { return false }
        // Before the news test below, so a row that turns out to be exactly as tall as it was at
        // the old width still stops being owed a measurement.
        stale.remove(contentKey)
        let rounded = Self.rounded(height)
        guard !Self.isSameHeight(heights[contentKey] ?? -1, rounded) else { return false }
        // See `mostRows`. Asked before the insert, so the cache never holds more than it says.
        if heights.count >= Self.mostRows, heights[contentKey] == nil { forget() }
        let previous = heights[contentKey] ?? 0
        total += rounded - previous
        if previous > 0 { inked -= 1 }
        if rounded > 0 { inked += 1 }
        heights[contentKey] = rounded
        settleIfItIsTime()
        return true
    }

    /// Takes the estimate, if there is enough to take it from and it is worth taking again.
    ///
    /// Once at `settleAfter`, and after that only when the sample has doubled AND the running mean
    /// disagrees with what is held by more than `resettleDrift`. Both of those, so that a good
    /// first screenful settles the number for the whole session and a bad one is not permanent.
    private mutating func settleIfItIsTime() {
        guard inked >= Self.settleAfter else { return }
        let running = total / Double(inked)
        guard let settled else {
            take(running)
            return
        }
        guard inked >= settledFrom * 2 else { return }
        guard abs(running - settled) > settled * Self.resettleDrift else { return }
        take(running)
    }

    private mutating func take(_ estimate: Double) {
        settled = estimate
        settledFrom = inked
    }

    /// Rounded up to a whole point, and never below nothing.
    ///
    /// Up rather than to nearest, because a row given a fraction less than it asked for has its
    /// last line clipped, and half a point of air under a row is invisible. See the header for why
    /// nought is kept rather than treated as a failure.
    public static func rounded(_ height: Double) -> Double {
        max(0, height.rounded(.up))
    }

    /// Empties the cache without changing the width it is for. What a text size change and a
    /// finished resize both come down to.
    public mutating func forget() {
        heights.removeAll()
        stale.removeAll()
        total = 0
        inked = 0
        settled = nil
        settledFrom = 0
    }
}
