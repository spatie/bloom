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

    /// **Plain text while it is still arriving, markdown once it has landed.**
    ///
    /// Every crash of one shape, `EXC_BAD_ACCESS` and once an impossible allocation inside SwiftUI's
    /// stack layout with no frame of ours on the stack, landed while a long answer was streaming,
    /// and the layout frames that were there read back to this row's `MarkdownBlocksView`: a stack
    /// over a `ForEach` of blocks, several of them `NSTextView`s, whose number and kinds change
    /// with every delta. A single `Text` has no stack of blocks to change under itself.
    ///
    /// It costs the jump `StreamingRowView` describes: a fenced block shows its markers as prose
    /// until the answer lands and then becomes a code block. That was the reason streaming moved to
    /// `MarkdownView`, and it is a smaller cost than an app that quits while somebody reads it.
    @ViewBuilder
    private var prose: some View {
        if isStreaming {
            Text(verbatim: text)
        } else {
            MarkdownView(text)
        }
    }
}
