import SwiftUI
import BloomUI

/// Live and saved messages share their boundaries and the Mac's native rich text adapter.
struct ProseRowView: View {
    var text: String
    var isStreaming = false

    var body: some View {
        BloomAssistantProse(
            maxWidth: TranscriptLayout.proseMeasure,
            horizontalInset: TranscriptLayout.inset,
            verticalInset: TranscriptLayout.block,
            separatorColor: Palette.border,
            separatorHeight: Metrics.hairline
        ) {
            MarkdownView(text, isStreaming: isStreaming)
                .font(Typo.body)
                .proseLeading()
        }
    }
}
