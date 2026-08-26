import SwiftUI
import BloomCore

/// What the tool gave back. A rule down the left rather than a filled block, so the answer reads as
/// quoted output rather than as another thing the agent wrote.
///
/// The rule is the quote mark and nothing else, so it stays the border colour whatever the output
/// says. Failure is carried by the text, which is set in the alarm colour from the first character
/// to the last, and by the word on the row above. A rule that changed colour too was the third
/// copy of one fact.
struct ToolResultView: View {
    var text: String
    var isError: Bool

    @State private var showsAll = false

    var body: some View {
        // Measured at the FOLDED cap either way round, because what decides whether there is a
        // control here is whether there is more output than the fold shows, and the opened-out
        // text answers no to that. It used to be asked of whichever version was on screen, which
        // is how the way back left the screen the moment somebody took it.
        let folded = TextCap.cap(text, lines: TextCap.lineCap)
        let shown = showsAll ? TextCap.cap(text, lines: .max).text : folded.text

        VStack(alignment: .leading, spacing: TranscriptLayout.tight * 2) {
            Text(shown)
                .font(Typo.code)
                .foregroundStyle(isError ? Palette.negative : Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, TranscriptLayout.block)
                .padding(.vertical, TranscriptLayout.tight)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Palette.border)
                        .frame(width: TranscriptLayout.rule)
                }

            if folded.truncated {
                Button(TextFold.title(isExpanded: showsAll)) { showsAll.toggle() }
                    .linkButton()
                    .font(Typo.caption)
                    .padding(.leading, TranscriptLayout.block)
            }
        }
    }
}
