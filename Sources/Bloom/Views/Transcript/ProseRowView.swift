import SwiftUI

/// Shared by live and saved messages so their boundaries do not move when streaming finishes.
struct ProseRowView: View {
    var text: String
    var isStreaming = false
    /// Present only on the response that closes a completed turn.
    var copyText: String?
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: TranscriptLayout.block) {
            prose
                .font(Typo.body)
                .proseLeading()
                .textSelection(.enabled)
                // Capped, then left aligned in whatever is left. One frame would centre the column
                // in a wide pane and take the paragraph off the line every other row starts on.
                .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The slot stays present while streaming and on intermediate prose, so completion
            // reveals a control without narrowing the response and changing its line breaks.
            Group {
                if let copyText, !copyText.isEmpty {
                    CopyButton(
                        text: copyText,
                        title: "Copy this answer",
                        isVisible: isHovered,
                        size: 18,
                        imageScale: .small
                    )
                } else {
                    Color.clear
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 18, height: 18)
        }
        .padding(.horizontal, TranscriptLayout.inset)
        // Equal air above and below keeps an activity disclosure centred between paragraphs.
        .padding(.top, TranscriptLayout.block)
        .padding(.bottom, TranscriptLayout.block)
        .onHover { isHovered = $0 }
    }

    /// Keep the live answer in one text view. The full block tree changes shape on every delta,
    /// which previously crashed SwiftUI's stack layout during long streamed answers.
    @ViewBuilder
    private var prose: some View {
        if isStreaming {
            StreamingMarkdownView(text)
        } else {
            MarkdownView(text)
        }
    }
}
