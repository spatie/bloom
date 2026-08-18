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
    /// The column a bullet, an ordinal or a task box sits in. Scaled at the call site.
    static let markerWidth: CGFloat = 24
    /// Room for a four digit line number. Scaled at the call site.
    static let lineNumberWidth: CGFloat = 28
    /// A square hit area for the small icon buttons in a code fence, so the glyph swapping from
    /// "copy" to "checkmark" does not resize the bar under the pointer.
    static let iconButton: CGFloat = 16
}
