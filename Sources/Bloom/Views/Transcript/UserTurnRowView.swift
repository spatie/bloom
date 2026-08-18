import SwiftUI

/// What the user asked for, as one side of a conversation.
struct UserTurnRowView: View {
    var text: String
    var maxWidth: CGFloat

    /// How much of the pane a user turn always leaves empty on its left, so it reads as one side of
    /// a conversation even when it is short.
    private static let inset: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: Self.inset)

            Text(text)
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)
                .lineSpacing(TranscriptLayout.proseLeading)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, TranscriptLayout.block)
                .padding(.vertical, TranscriptLayout.inset)
                .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.corner)
                        .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
                }
                .frame(maxWidth: maxWidth, alignment: .trailing)
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.inset)
    }
}
