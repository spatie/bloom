import Foundation
import SwiftUI

/// Shared geometry, so a thinking row, a tool row and a footer all land on the same columns. The
/// alignment is the point: it is what turns a list of events into something scannable.
///
/// There is one scale here rather than a literal at every call site, because a transcript that
/// streams new rows in is only calm if every row type agrees on where its columns start.
///
/// The three spacings below are the window's scale rather than numbers of their own, so the
/// transcript cannot drift a point away from the sidebar and the inspector the way it did when
/// all three kept private copies. The column widths underneath them are genuinely the
/// transcript's, because nothing else in the window has a glyph column or a label column.
enum TranscriptLayout {
    /// The gap between two things that belong to each other, such as a label and its counter.
    static let tight = Metrics.spacingTight
    /// The horizontal inset a row keeps, and the general gap between pieces.
    ///
    /// Deliberately `spacing` and not `Metrics.inset`: a transcript row already carries a glyph
    /// column and a label column, so it reads as indented at the sidebar's wider pane inset. The
    /// name is the transcript's, the number is the window's.
    static let inset = Metrics.spacing
    /// Between stacked blocks inside an expanded row.
    static let block = Metrics.spacingWide

    /// The air under a turn's footer, before the next question.
    ///
    /// Twice the rung the answer keeps above the footer's rule, and the asymmetry is the only
    /// thing that says which turn the time belongs to. The footer used to sit in the middle of a
    /// gap it shared with the turn below, so a column of finished turns read as a time floating
    /// between two questions rather than as the line that closes the one above it. Twice is as
    /// far as this goes: at three the gap stops reading as a paragraph break and starts reading
    /// as a row that failed to draw.
    static let turnGap: CGFloat = block * 2

    /// The pitch of a one line row, and the transcript's own rather than the window's.
    ///
    /// A source list row is 28 points because it holds a name the user chose and clicks on all
    /// day. A transcript row holds a receipt: it is read in blocks of twenty at a time, it is
    /// clicked rarely, and at the source list's pitch a turn's worth of them took more of the pane
    /// than the answer they led to. Four points off each closed the gaps inside the block without
    /// touching the text in it, and the row is still taller than the line it draws at any text
    /// size, which is what `fontScale` here is for.
    static let rowHeight: CGFloat = 24

    static let glyphWidth: CGFloat = 16
    static let glyphGap: CGFloat = 8
    /// The label column, at the default text size. Read through `transcriptLabelColumn()` rather
    /// than directly, because it is the one column here that holds text of unknown length.
    static let labelWidth: CGFloat = 176
    /// Where an expanded body starts, lined up under the label column.
    static let detailIndent: CGFloat = glyphWidth + glyphGap + inset
    static let nestIndent: CGFloat = 16
    /// The coloured rule down the left of an error, a quote or a tool result.
    static let rule: CGFloat = 2
    /// Wide enough for `chevron.down`, which is half again as wide as `chevron.right`. At 10 the
    /// open chevron overflowed its own box and the row's trailing edge shifted on every toggle.
    static let disclosureWidth: CGFloat = 14
    /// The horizontal inset a `Chip` keeps, so a chip drawn by hand is the same shape as one that
    /// is not, which matters in the footer where the two sit next to each other.
    static let chipInset = Metrics.chipInsetH
    /// Extra leading for the two places that render real prose rather than one line.
    static let proseLeading: CGFloat = 3
    /// How wide a paragraph is allowed to get.
    ///
    /// Nothing else in the window is read a line at a time, so nothing else needs a measure. With
    /// the inspector closed on a large display the transcript pane is well over a thousand points
    /// and a paragraph ran to nearly two hundred characters, which is the width at which the eye
    /// loses the start of the next line. Generous on purpose: at the sizes the window is usually
    /// dragged to this never bites, and it only ever stops prose running away.
    static let proseMeasure: CGFloat = 680
}

/// The label column of a row header.
///
/// Fixed columns are what make the transcript scan, but this one holds text nobody chose the
/// length of ("Run Pint and the new test"), so it is the one that has to grow with the user's text
/// size. The glyph and detail columns stay pinned, so an expanded body still lands under the label
/// it belongs to whatever size the text is set at.
struct TranscriptLabelColumn: ViewModifier {
    /// Was a `@ScaledMetric`, which on macOS never moves because there is no Dynamic Type for it to
    /// track, so the column stayed at 176 however large the conversation was set.
    @Environment(\.fontScale) private var fontScale

    func body(content: Content) -> some View {
        content.frame(width: TranscriptLayout.labelWidth * fontScale, alignment: .leading)
    }
}

extension View {
    func transcriptLabelColumn() -> some View {
        modifier(TranscriptLabelColumn())
    }
}
