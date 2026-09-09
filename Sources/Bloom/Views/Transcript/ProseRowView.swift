import SwiftUI
import BloomUI

/// The Mac supplies its native rich text adapter inside the shared reading column.
struct ProseRowView: View {
    var text: String

    var body: some View {
        BloomAssistantProse(
            maxWidth: TranscriptLayout.proseMeasure,
            horizontalInset: TranscriptLayout.inset,
            verticalInset: TranscriptLayout.block
        ) {
            MarkdownView(text)
                .font(Typo.body)
                .proseLeading()
        }
    }
}
