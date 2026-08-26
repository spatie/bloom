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
/// A row's height depends on three things: what it draws, how wide it is drawn, and the text size
/// it is drawn at. The obvious spelling folds all three into one key, which is what the spike did,
/// and it is wrong in a way that only shows up after a while: the pane is resized all day, so the
/// cache accumulates one entry per row per width it has ever been, none of which will ever be
/// asked for again. Width and scale are properties of the whole cache instead, held once, and
/// changing either empties it. That is also the truthful shape, because there is never more than
/// one width in play.
///
/// ## A live resize does not remeasure, on purpose
///
/// Every cached height was taken at a width that no longer holds, so all of them are wrong the
/// moment a divider moves, and taking them again is a whole SwiftUI layout per row per frame of
/// the drag. So the caller runs the drag on stale heights, which is visibly wrong for any row
/// whose text rewraps, and rebuilds once when the hand comes off. A resize is cheap and wrong for
/// a moment rather than expensive and right. `reset(width:scale:)` is where that lands.
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
        ///
        /// Half a point of width, because a scroll view's own arithmetic lands on fractions and a
        /// row laid out at 831.5 points is the same row as one laid out at 831.75. Anything
        /// coarser and a real drag would fail to invalidate; anything finer and a rounding error
        /// would empty the cache for nothing.
        func matches(_ other: Measure) -> Bool {
            abs(width - other.width) <= 0.5 && scale == other.scale
        }
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
    private var heights: [String: Double] = [:]

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
        return true
    }

    /// The remembered height of this content, or nothing if it has never been measured.
    public func height(for contentKey: String) -> Double? {
        heights[contentKey]
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
    public mutating func note(_ height: Double, for contentKey: String) -> Bool {
        guard measure != nil else { return false }
        let rounded = Self.rounded(height)
        guard abs((heights[contentKey] ?? -1) - rounded) > 0.5 else { return false }
        heights[contentKey] = rounded
        return true
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
    }
}
