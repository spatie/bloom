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

    var body: some View {
        HStack(spacing: 0) {
            gutter
            content
        }
        .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
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
        // One element per line, said as a sentence. Left as it was drawn, VoiceOver read a row as
        // four unrelated fragments, "128", "129", "+", and then the code, and whether a line was
        // added or removed reached the reader only as a background wash and a one-character
        // marker that is a bare space on a context line. A colour is not a label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHidden(line == nil)
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
