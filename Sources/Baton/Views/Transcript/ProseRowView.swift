import SwiftUI

/// A finished block of assistant prose, rendered as markdown.
struct ProseRowView: View {
    var text: String

    var body: some View {
        MarkdownView(text)
            .font(Typo.body)
            .lineSpacing(TranscriptLayout.proseLeading)
            .textSelection(.enabled)
            // Capped, then left aligned in whatever is left. One frame would centre the column
            // in a wide pane and take the paragraph off the line every other row starts on.
            .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TranscriptLayout.inset)
            .padding(.vertical, TranscriptLayout.inset)
    }
}
