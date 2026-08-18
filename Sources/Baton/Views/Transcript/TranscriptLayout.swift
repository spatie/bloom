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

    static let glyphWidth: CGFloat = 16
    static let glyphGap: CGFloat = 8
    static let labelWidth: CGFloat = 176
    /// Where an expanded body starts, lined up under the label column.
    static let detailIndent: CGFloat = glyphWidth + glyphGap + inset
    static let nestIndent: CGFloat = 16
    /// The coloured rule down the left of an error, a quote or a tool result.
    static let rule: CGFloat = 2
    static let disclosureWidth: CGFloat = 10
    /// The horizontal inset a `Chip` keeps, so a chip drawn by hand is the same shape as one that
    /// is not, which matters in the footer where the two sit next to each other.
    static let chipInset: CGFloat = 5
    /// Extra leading for the two places that render real prose rather than one line.
    static let proseLeading: CGFloat = 3
}
