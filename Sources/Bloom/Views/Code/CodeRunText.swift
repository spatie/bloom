import SwiftUI
import BloomCore

/// One line of a run, and everything drawing it needs that is not shared with its neighbours.
///
/// The carry is per line rather than per run because the lexer carries block comments, heredocs
/// and multiline strings forward, and a run does not always start where a hunk does.
struct CodeRunLine: Equatable {
    var text: String
    var carry: LexState = LexState()
    /// Word level diff spans, in indices over `text`.
    var emphasis: [Range<String.Index>] = []
    var emphasisColor: Color = .clear
}

/// Several syntax highlighted lines of source as ONE text object, so a selection runs across them.
///
/// **This is the whole of the fix for "text on multiple lines is not selectable".** Sibling `Text`
/// views are separate selection scopes on this system: `.textSelection(.enabled)` selects within
/// one and cannot span two, so a diff drawn as a `Text` per line let the reader select the single
/// line a drag began on and no more. `CodeBlockView` hit the identical report about a markdown
/// fence and answered it the same way, and its note is worth reading beside this one.
///
/// Joining costs the colours nothing. `CodeText.attributed` hands back a line whose highlighting
/// and word level emphasis are already attribute runs on the string, and concatenation carries a
/// run's attributes with it. It costs the memoisation nothing either: every line still goes
/// through `SyntaxCache` on its own key, so a line redrawn in a run and a line redrawn on its own
/// are the same cache hit.
///
/// What it does cost is the lazy stack's granularity, since a run is one item however many lines
/// it holds. That is why `DiffRunGrouping` caps a run rather than taking a whole hunk, and the
/// measurements behind the cap are on `DiffRunGrouping.runLimit`.
struct CodeRunText: View, Equatable {
    var lines: [CodeRunLine]
    var language: Language

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.language == rhs.language && lhs.lines == rhs.lines
    }

    var body: some View {
        Text(joined)
            // `CodeMetrics.measuredFont` rather than `Typo.code`, and that is the whole of what
            // keeps this level: a text style rung does not take `.lineSpacing` at face value.
            // The measurement, and what it cost, are on `measuredFont` itself.
            .font(CodeMetrics.measuredFont)
            // Each line box has to come out at exactly `CodeMetrics.rowHeight`, because the gutter
            // beside this is still one fixed height view per line and the two have to stay level
            // over hundreds of rows. `rowSpacing` is that arithmetic.
            .lineSpacing(CodeMetrics.rowSpacing)
            .textSelection(.enabled)
            // Unwrapped, for the reason the sheet is sized off the widest line in the file: the
            // whole diff scrolls sideways as one, and a run that wrapped would take rows with it
            // and throw the gutter out of step for everything below.
            .fixedSize(horizontal: true, vertical: false)
            // Spacing falls BETWEEN lines, so a run of n lines is one natural line plus n - 1
            // gaps, which is half a gap short at each end of the n * rowHeight the gutter draws.
            // Measured offscreen: seven lines came out at 126.0 points against 7 * 18, exactly,
            // with this padding and three short without it.
            .padding(.vertical, CodeMetrics.rowSpacing / 2)
    }

    private var joined: AttributedString {
        var output = AttributedString()
        for (offset, line) in lines.enumerated() {
            if offset > 0 { output += AttributedString("\n") }
            output += CodeText.attributed(
                line: line.text,
                language: language,
                carry: line.carry,
                emphasis: line.emphasis,
                emphasisColor: line.emphasisColor
            )
        }
        return output
    }
}
