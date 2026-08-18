import SwiftUI

/// What the agent is doing when it has not said anything yet. A dot rather than a spinner when
/// there is no glyph to show, so an idle-looking turn still reads as alive.
struct StreamingStatusView: View {
    var glyph: String?
    var text: String

    var body: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            if let glyph {
                TranscriptGlyph(symbol: glyph, tint: Palette.running)
            } else {
                ActivityDot(isActive: true)
                    .frame(width: TranscriptLayout.glyphWidth)
            }

            Text(text)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .frame(height: Metrics.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
