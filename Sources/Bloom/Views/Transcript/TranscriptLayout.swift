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
/// all three kept private copies. The widths underneath them are genuinely the transcript's,
/// because nothing else in the window has a glyph column.
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

    /// What a held-open card keeps inside its border, and the gap between the groups inside it.
    ///
    /// Wider than `inset`, deliberately. The question card is the one form in the transcript,
    /// and at the row inset its header, its question and its options all sat on each other and
    /// the card read as a list that happened to have a border. One value for both the margin and
    /// the group gap, so the air inside the card is the same air that separates it from its edge.
    static let cardInset = Metrics.gutter

    /// Where an option row's text column starts, measured from the card margin: the row plate's
    /// own inset, then the mark column and its gap. The preview block under a chosen option
    /// hangs at this indent so it reads as part of the option rather than as a row of its own.
    static let optionTextIndent = Metrics.spacingWide + glyphWidth + glyphGap

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
    /// The widest a row's label may be drawn, at the default text size, which is not the width it
    /// is drawn at. Read through `transcriptLabelColumn(_:font:)`, where a label's own width is
    /// worked out and where the reason for the ceiling being this number is written down.
    static let labelCeiling: CGFloat = 176
    /// Where an expanded body starts, lined up under the label. Built from the glyph column and
    /// not from the label's own width, which is why nothing below a row moved when that stopped
    /// being a fixed number.
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
    /// Extra leading for a block of code that wraps, which is the permission panel's command.
    ///
    /// A point more than prose gets, and decided on its own rather than borrowed from it. A
    /// wrapped shell command is the hardest thing in the window to read: it has no sentence shape
    /// to fall back on, the eye has to find the start of the next line by position alone, and set
    /// solid at eleven points a continuation line sat as close to its own predecessor as two
    /// separate commands would. Four points on a thirteen point line box is a line height of about
    /// 1.3, which is the ratio code is set at in every editor and is a rung of the spacing scale
    /// rather than a number invented here.
    static let codeLeading: CGFloat = Metrics.spacingSmall
    /// How wide a paragraph is allowed to get.
    ///
    /// Nothing else in the window is read a line at a time, so nothing else needs a measure. With
    /// the inspector closed on a large display the transcript pane is well over a thousand points
    /// and a paragraph ran to nearly two hundred characters, which is the width at which the eye
    /// loses the start of the next line. Generous on purpose: at the sizes the window is usually
    /// dragged to this never bites, and it only ever stops prose running away.
    static let proseMeasure: CGFloat = 680
}
