import SwiftUI

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
        let capped = TextCap.cap(text, lines: showsAll ? .max : TextCap.lineCap)

        VStack(alignment: .leading, spacing: TranscriptLayout.tight * 2) {
            Text(capped.text)
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

            if capped.truncated, !showsAll {
                Button("Show all output") { showsAll = true }
                    .buttonStyle(.link)
                    .font(Typo.caption)
                    .padding(.leading, TranscriptLayout.block)
            }
        }
    }
}
