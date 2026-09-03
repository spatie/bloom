import SwiftUI
import BloomCore

/// One rendered diff line: gutter numbers, the marker column, and the highlighted source.
///
/// The same view serves both layouts. Unified asks for both number columns, side by side asks for
/// one and is given an explicit width so the two panes stay aligned even when a line is empty.
///
/// **Most rows are no longer drawn by this.** A `Text` per line cannot be selected across two of
/// them, so consecutive lines are grouped into a `DiffRunView` and drawn as one text object; see
/// `DiffRunGrouping` for what stops a run. What is left here is every row a run may not swallow:
/// a lone line between two comment bands, the line above an expander, the last line of a hunk.
/// The two must look identical, which is why the gutter, the marker and the `+` are shared views
/// rather than a copy each.
struct DiffLineView: View, Equatable {
    /// A row redraws when what it holds changes, and not because the closure beside it is a new
    /// closure. `onComment` is written at the call site as `{ beginDraft(at: $0) }`, so it is a
    /// freshly allocated function on every pass over the diff, and functions are never equal to
    /// one another: without this SwiftUI has to assume every row differs from the one it drew a
    /// moment ago, and a diff of a few hundred realised rows rebuilds all of them whenever
    /// anything at all moves in the view above.
    ///
    /// `onComment` is not among the fields compared, and cannot be. Conforming to `View` makes
    /// this type main actor isolated, `Equatable.==` is a nonisolated requirement, and a function
    /// type is not `Sendable`, so a `nonisolated ==` may not so much as ask whether the closure is
    /// nil. It does not need to: whether the `+` is offered at all is decided by `offeredSpot`
    /// from `line` and `numbers`, both of which are compared, and the two call sites that ask for
    /// this comparison are the two halves of one diff and always hand it the same kind of closure.
    /// `onEdit` is left out for the same reasons and answers to the same argument: whether the
    /// menu offers an edit is decided by `editableLine` from `line` and `numbers`, both compared.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line
            && lhs.language == rhs.language
            && lhs.carry == rhs.carry
            && lhs.emphasis == rhs.emphasis
            && lhs.numbers == rhs.numbers
            && lhs.width == rhs.width
            && lhs.isCommented == rhs.isCommented
    }

    /// Which gutters this row shows. The enum moved to `DiffGutter` when the run view came to
    /// need it too; this keeps `DiffLineView.Numbers` naming the same type it always did.
    typealias Numbers = DiffGutter.Numbers

    var line: DiffLine?
    var language: Language
    var carry: LexState = LexState()
    var emphasis: [Range<String.Index>] = []
    var numbers: Numbers = .both
    /// Total width of the row, including gutters. Fixed by the file's widest line so every row
    /// scrolls horizontally as one sheet rather than each row scrolling on its own.
    var width: CGFloat
    /// Whether a pending review comment is anchored here, which tints the row as under
    /// discussion the way the band under it is.
    var isCommented: Bool = false
    /// Opens the review comment editor at this line. Nil, the default, draws no `+` at all,
    /// which is what every caller that is not the review's own diff wants.
    var onComment: ((ReviewSpot) -> Void)?
    /// Opens the in-place editor on the lines around this one, by its new-side number. Nil, the
    /// default, offers nothing, which is what every caller outside the review's own diff wants.
    var onEdit: ((Int) -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            DiffGutter(line: line, numbers: numbers)
            content
        }
        .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
        // One element per line, said as a sentence. The wording, and why a colour is not a label,
        // are on `DiffGutter.speech`.
        //
        // Collapsed HERE, before the comment button's overlay, and not at the foot of the body.
        // `children: .ignore` swallows every descendant of whatever it is applied to, so applied
        // after the overlay it removed the button from the accessibility tree, measured by the
        // button vanishing from the AX hierarchy, and the claim in `DiffCommentButton`'s comment
        // that a keyboard and VoiceOver can reach it was quietly false. In this order the row is
        // one spoken sentence and the button is its sibling, which is both true and reachable.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DiffGutter.speech(for: line))
        .accessibilityHidden(line == nil)
        .overlay(alignment: .leading) { commentButton }
        // The whole row is the hover target, and it has to be said, because a view's hit region
        // is only what it draws. Most of a diff row draws nothing: a context line paints no wash,
        // and the frame is taller and wider than the type inside it, so the pointer found the row
        // only along the band of pixels the glyphs themselves cover, and the `+` flickered in and
        // out as the pointer crossed the ascenders. The shape is the frame set above, the sheet's
        // width by `rowHeight`, so rows hand the hover to each other with no dead band between.
        // Applied outside the button's overlay so the button sits inside the tracked region
        // rather than cutting a hole in it at the leading edge, and after the accessibility
        // collapse, which must stay directly above the overlay for the reason given there.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // Over the diff wash, not instead of it: an addition under review stays an addition,
        // and the amber says "under discussion" on top of whatever the line already was.
        .background(isCommented ? Palette.reviewLine : .clear)
        // Painted here, on the row, rather than on the gutter and the code separately, which is
        // what left a band of pane colour between a removed line and the added line under it.
        // `CodeMetrics.rowHeight` is a line of type plus three points of air, and an `HStack`
        // takes the height of its tallest child, so the two washes were drawn at TYPE height and
        // centred in the row: a point and a half of unpainted ground above and below every one of
        // them, and three points between any two. A replacement read as two separate events.
        //
        // Nothing about the rhythm of the file changes. The row is the height it always was and
        // an unchanged line still paints nothing, so only the lines that were already coloured
        // are affected, and they now meet. Behind the content rather than over it, so the word
        // level emphasis inside `CodeText` still sits on top and is neither moved nor clipped.
        .background(DiffWash.background(of: line))
        // The same action the `+` in the gutter carries, on the right click as well.
        //
        // A control that only appears under the pointer is a control most people never learn is
        // there, and this one is the whole of inline review commenting: nothing else in the app
        // starts a comment. The right click is where a Mac user asks "what can I do with this
        // line", and a context menu item is a real answer rather than a consolation for not having
        // put it in the menu bar: a comment is about one line, and the menu bar has no way to say
        // which line.
        //
        // Attached to the row and not to the gutter, because the right click lands wherever the
        // pointer is and the code is most of the row. Absent, rather than greyed, on a row with no
        // spot to anchor to, which is what every caller outside the review's own diff gets.
        //
        // Editing the lines in place is the second item, and the right click is the whole of how
        // it is reached. The gutter has room for one hover control and it belongs to the `+`,
        // which is the older of the two and the one that starts the review; a second button
        // beside it would have to be found before either could be used, and both would be
        // narrower for it. What the item opens is `DiffEdit.region`, which may refuse, and the
        // refusal is what the reader is shown.
        .contextMenu {
            if let spot = offeredSpot {
                Button("Comment on This Line") { onComment?(spot) }
            }
            if let line = editableLine, let onEdit {
                Button("Edit These Lines") { onEdit(line) }
            }
        }
    }

    // MARK: - Commenting

    /// The spot a comment left on this row would anchor to, filtered to the side this view is
    /// drawing. The rule is `DiffCommentSpot`, shared with the run view.
    private var offeredSpot: ReviewSpot? {
        DiffCommentSpot.offered(for: line, numbers: numbers, enabled: onComment != nil)
    }

    /// The new-side line an in-place edit begun on this row would open on. The rule is
    /// `DiffEditTarget`, shared with the run view for the reason `DiffCommentSpot` is.
    private var editableLine: Int? {
        DiffEditTarget.offered(for: line, numbers: numbers, enabled: onEdit != nil)
    }

    @ViewBuilder
    private var commentButton: some View {
        if let spot = offeredSpot, let onComment {
            DiffCommentButton(spot: spot, isRowHovered: isHovered, onComment: onComment)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let line {
            switch line.kind {
            case .noNewline:
                HStack(spacing: 0) {
                    DiffMarker(line: line)
                    Text("No newline at end of file")
                        .font(Typo.codeTiny)
                        .foregroundStyle(Palette.textTertiary)
                        .italic()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                // The word level emphasis is a background on the glyph runs inside `CodeText`, so
                // it paints over the row tint underneath rather than replacing it. Both are needed:
                // the tint says the line changed, the emphasis says which part of it did.
                HStack(spacing: 0) {
                    DiffMarker(line: line)
                    CodeText(line: line.text, language: language, carry: carry)
                        .emphasizing(emphasis, color: DiffWash.emphasis(of: line))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Padding opposite a longer run on the other side. Sunken rather than empty, so the
            // eye reads it as "nothing here" instead of "unchanged".
            Rectangle()
                .fill(Palette.surfaceSunken)
                .frame(maxWidth: .infinity)
        }
    }
}

/// What a diff line is painted with.
///
/// Two colours, asked for by the per line rows and by the run rows, which paint them in different
/// places: `DiffLineView` as the row's own background, `DiffRunView` as a layer behind a column of
/// lines. One answer, so a run and the lone line under it cannot come out different greens.
enum DiffWash {
    /// The wash that says the line changed.
    static func background(of line: DiffLine?) -> Color {
        switch line?.kind {
        case .addition: Palette.diffAddBackground
        case .deletion: Palette.diffDeleteBackground
        default: .clear
        }
    }

    /// The stronger tint that says WHICH PART of it changed, painted on the glyph runs on top.
    static func emphasis(of line: DiffLine?) -> Color {
        switch line?.kind {
        case .addition: Palette.diffAddEmphasis
        case .deletion: Palette.diffDeleteEmphasis
        default: .clear
        }
    }
}
