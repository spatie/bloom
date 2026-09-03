import SwiftUI

/// A finished block of assistant prose, rendered as markdown.
struct ProseRowView: View {
    var text: String

    var body: some View {
        MarkdownView(text)
            .font(Typo.body)
            .proseLeading()
            .textSelection(.enabled)
            // Capped, then left aligned in whatever is left. One frame would centre the column
            // in a wide pane and take the paragraph off the line every other row starts on.
            .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TranscriptLayout.inset)
            // More than a row keeps, and deliberately. An answer is the one thing in this pane
            // that is read rather than scanned, and what sets it apart from the list of actions
            // above and below it is the space around it as much as the size it is set in.
            .padding(.vertical, TranscriptLayout.block)
    }
}
