import SwiftUI
import BatonCore

/// A tool result whose call never made it into the transcript. Rare, but it must not vanish.
struct OrphanResultRowView: View {
    var result: AgentToolResult

    var body: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "arrow.turn.down.right")

            Text(ToolPresenter.oneLine(result.text))
                .font(Typo.label)
                .foregroundStyle(result.isError ? Palette.negative : Palette.textTertiary)
                .lineLimit(1)
                // The only copy of an output whose call never arrived, so it has to be liftable.
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .transcriptRowFrame()
    }
}
