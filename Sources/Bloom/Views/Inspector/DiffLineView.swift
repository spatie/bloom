import SwiftUI
import BloomCore

/// One rendered diff line: gutter numbers, the marker column, and the highlighted source.
///
/// The same view serves both layouts. Unified asks for both number columns, side by side asks for
/// one and is given an explicit width so the two panes stay aligned even when a line is empty.
struct DiffLineView: View {
    /// Which gutters this row shows. Side by side shows one, unified shows both.
    enum Numbers {
        case both
        case old
        case new
    }

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
    var onComment: ((ReviewSpot) -> Void)? = nil

    @State private var isHovered = false
    @FocusState private var isPlusFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            gutter
            content
        }
        .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
        // One element per line, said as a sentence. Left as it was drawn, VoiceOver read a row as
        // four unrelated fragments, "128", "129", "+", and then the code, and whether a line was
        // added or removed reached the reader only as a background wash and a one-character
        // marker that is a bare space on a context line. A colour is not a label.
        //
        // Collapsed HERE, before the comment button's overlay, and not at the foot of the body.
        // `children: .ignore` swallows every descendant of whatever it is applied to, so applied
        // after the overlay it removed the button from the accessibility tree, measured by the
        // button vanishing from the AX hierarchy, and the claim in `commentButton`'s comment that
        // a keyboard and VoiceOver can reach it was quietly false. In this order the row is one
        // spoken sentence and the button is its sibling, which is both true and reachable.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHidden(line == nil)
        .onHover { isHovered = $0 }
        .overlay(alignment: .leading) { commentButton }
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
        .background(background)
    }

    /// What this line is, where it is, and what it says, in that order.
    private var accessibilityLabel: String {
        guard let line else { return "" }
        if line.kind == .noNewline { return "No newline at end of file" }

        let number = line.newNumber ?? line.oldNumber
        let place = number.map { " \($0)" } ?? ""
        let state = switch line.kind {
        case .addition: "Added line\(place)"
        case .deletion: "Removed line\(place)"
        default: "Line\(place)"
        }

        let text = line.text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "\(state), empty" : "\(state), \(text)"
    }

    // MARK: - Commenting

    /// The spot a comment left on this row would anchor to, filtered to the side this view is
    /// drawing. In side by side a context line appears in both panes; only the new-side pane
    /// offers it, so one line never grows two buttons meaning the same thing.
    private var offeredSpot: ReviewSpot? {
        guard onComment != nil, let spot = line?.reviewSpot else { return nil }
        switch numbers {
        case .both: return spot
        case .old: return spot.side == .old ? spot : nil
        case .new: return spot.side == .new ? spot : nil
        }
    }

    /// The `+` in the gutter, sitting over the line number the way Conductor draws it.
    ///
    /// Always in the hierarchy and hidden by drawing in clear rather than built on hover or
    /// faded with `.opacity`, so it is reachable by Tab under Full Keyboard Access and readable
    /// by VoiceOver: a control that only exists while a pointer floats over it is a control a
    /// keyboard can never reach. Not `.opacity(0)`, on the button or on its label, because
    /// either took the element out of the accessibility tree entirely, measured by it vanishing
    /// from the AX hierarchy, which silently broke the sentence before this one. Clear colours
    /// draw the same nothing while the button keeps its hit region and its element, which is
    /// also what makes the hover reveal feel instant.
    @ViewBuilder
    private var commentButton: some View {
        if let spot = offeredSpot {
            let shown = isHovered || isPlusFocused
            Button {
                onComment?(spot)
            } label: {
                Image(systemName: "plus")
                    .font(Typo.micro)
                    .fontWeight(.bold)
                    .foregroundStyle(shown ? Palette.textInverted : .clear)
                    .frame(width: 16, height: 16)
                    .background(
                        shown ? Palette.accentFill : .clear,
                        in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isPlusFocused)
            .padding(.leading, Metrics.spacingTight)
            .help("Comment on this line")
            .accessibilityLabel("Comment on line \(spot.line)")
        }
    }

    // MARK: - Gutter

    @ViewBuilder
    private var gutter: some View {
        HStack(spacing: 0) {
            switch numbers {
            case .both:
                number(line?.oldNumber)
                number(line?.newNumber)
            case .old:
                number(line?.oldNumber)
            case .new:
                number(line?.newNumber)
            }
        }
        // No tint of its own. A grey column against the white the code sits on put a hard vertical
        // edge down the left of every diff, and a hard edge is read as a boundary between two
        // things rather than as the margin of one. The row's wash runs under this and under the
        // code alike, which leaves the numbers to be told apart by being dimmed and monospaced,
        // and that is what separates a ruler from content anyway.
    }

    /// Right aligned, dimmed and monospaced, so a column of numbers reads as a ruler rather than
    /// as content competing with the code beside it.
    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(Typo.codeTiny)
            .monospacedDigit()
            .foregroundStyle(Palette.textTertiary)
            .frame(width: CodeMetrics.numberWidth, alignment: .trailing)
            .padding(.trailing, CodeMetrics.gutterPadding)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let line {
            switch line.kind {
            case .noNewline:
                HStack(spacing: 0) {
                    marker
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
                    marker
                    CodeText(line: line.text, language: language, carry: carry)
                        .emphasizing(emphasis, color: emphasisColor)
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

    private var marker: some View {
        Text(markerText)
            .font(Typo.codeTiny)
            .foregroundStyle(Palette.textTertiary)
            .frame(width: CodeMetrics.markerWidth, alignment: .center)
    }

    private var markerText: String {
        switch line?.kind {
        case .addition: "+"
        case .deletion: "-"
        case .noNewline: "\\"
        default: " "
        }
    }

    private var background: Color {
        switch line?.kind {
        case .addition: Palette.diffAddBackground
        case .deletion: Palette.diffDeleteBackground
        default: .clear
        }
    }

    private var emphasisColor: Color {
        switch line?.kind {
        case .addition: Palette.diffAddEmphasis
        case .deletion: Palette.diffDeleteEmphasis
        default: .clear
        }
    }
}
