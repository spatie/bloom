import SwiftUI

/// A finished block of assistant prose, rendered as markdown.
struct ProseRowView: View {
    var text: String

    var body: some View {
        MarkdownView(text)
            .font(Typo.body)
            .lineSpacing(TranscriptLayout.proseLeading)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TranscriptLayout.inset)
            .padding(.vertical, TranscriptLayout.inset)
    }
}
