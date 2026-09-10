import SwiftUI

/// Shared by live and saved messages so their boundaries do not move when streaming finishes.
struct ProseRowView: View {
    var text: String
    var isStreaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.block) {
            Hairline()
                .accessibilityHidden(true)

            MarkdownView(text, isStreaming: isStreaming)
                .font(Typo.body)
                .proseLeading()
                .textSelection(.enabled)
                // Capped, then left aligned in whatever is left. One frame would centre the column
                // in a wide pane and take the paragraph off the line every other row starts on.
                .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.block)
    }
}
