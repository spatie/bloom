import Foundation

/// Shared geometry, so a thinking row, a tool row and a footer all land on the same columns. The
/// alignment is the point: it is what turns a list of events into something scannable.
///
/// There is one scale here rather than a literal at every call site, because a transcript that
/// streams new rows in is only calm if every row type agrees on where its columns start.
enum TranscriptLayout {
    /// The gap between two things that belong to each other, such as a label and its counter.
    static let tight: CGFloat = 2
    /// The inset every row keeps from the edge of the pane, and the general gap between pieces.
    static let inset: CGFloat = 6
    /// Between stacked blocks inside an expanded row.
    static let block: CGFloat = 8

    static let glyphWidth: CGFloat = 16
    static let glyphGap: CGFloat = 8
    static let labelWidth: CGFloat = 176
    /// Where an expanded body starts, lined up under the label column.
    static let detailIndent: CGFloat = glyphWidth + glyphGap + inset
    static let nestIndent: CGFloat = 16
    /// The coloured rule down the left of an error, a quote or a tool result.
    static let rule: CGFloat = 2
    static let disclosureWidth: CGFloat = 10
    /// Extra leading for the two places that render real prose rather than one line.
    static let proseLeading: CGFloat = 3
}
