import Foundation

/// The few dimensions that are markdown's own.
///
/// Everything else here comes from the window's spacing scale in `Metrics`, or from
/// `TranscriptLayout` where markdown draws the same thing a transcript row draws, such as a quoted
/// block. What is left is the handful of widths that only mean something inside prose. They used to
/// be borrowed from `Metrics.corner` and `Metrics.rowHeight`, which tied a bullet column to the row
/// height of a source list for no reason beyond both happening to be 28.
enum MarkdownMetrics {
    /// Between two top level blocks: paragraph to paragraph, paragraph to code fence.
    static let blockGap: CGFloat = 12
    /// The extra a heading takes above itself, on top of `blockGap`.
    ///
    /// A heading set the same distance from the paragraph above it as from the one below reads as
    /// belonging to neither. Space above is the whole of what makes it look attached to what it
    /// introduces, and it costs nothing at the top of a block where there is nothing above.
    static let headingLead: CGFloat = 10
    /// The column a bullet, an ordinal or a task box sits in. Scaled at the call site.
    static let markerWidth: CGFloat = 24
    /// A square hit area for the small icon buttons in a code fence, so the glyph swapping from
    /// "copy" to "checkmark" does not resize the bar under the pointer. Larger than the glyph it
    /// holds, because a 16 point target for a control that only appears once per block is a
    /// pointer exercise.
    static let iconButton: CGFloat = 20
}
