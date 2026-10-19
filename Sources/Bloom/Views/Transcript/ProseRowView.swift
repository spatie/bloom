import SwiftUI

/// Shared by live and saved messages so their boundaries do not move when streaming finishes.
struct ProseRowView: View {
    var text: String
    var isStreaming = false
    /// Present only on the response that closes a completed turn.
    var copyText: String?
    var smoothMarkdownHandoff = false
    @State private var isHovered = false
    @State private var markdownReady = false
    @State private var markdownSettled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// which previously crashed SwiftUI's stack layout during long streamed answers. Once saved,
    /// retain that drawing until the complete Markdown view has laid out, then fade between them.
    @ViewBuilder
    private var prose: some View {
        if isStreaming {
            StreamingMarkdownView(text)
        } else if smoothMarkdownHandoff {
            ZStack(alignment: .topLeading) {
                MarkdownView(text)
                    .onGeometryChange(for: Bool.self) { proxy in
                        proxy.size.width > 0 && proxy.size.height > 0
                    } action: { markdownReady = $0 }
                    .opacity(markdownSettled ? 1 : 0)
                    .allowsHitTesting(markdownSettled)
                    .accessibilityHidden(!markdownSettled)
                StreamingMarkdownView(text)
                    .opacity(markdownSettled ? 0 : 1)
                    .allowsHitTesting(!markdownSettled)
                    .accessibilityHidden(markdownSettled)
            }
            .task(id: markdownReady) {
                guard markdownReady, !markdownSettled else { return }
                // Draw the same text as the live tail for the first frames of the saved row.
                // The complete block layout is already in the stack when it fades in.
                try? await Task.sleep(for: .milliseconds(35))
                guard !Task.isCancelled else { return }
                if reduceMotion {
                    markdownSettled = true
                } else {
                    withAnimation(.easeOut(duration: 0.18)) { markdownSettled = true }
                }
            }
        } else {
            MarkdownView(text)
        }
    }
}
