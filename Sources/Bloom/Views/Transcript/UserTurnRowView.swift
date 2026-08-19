import SwiftUI
import BloomCore

/// What the user asked for, as one side of a conversation.
///
/// Files attached to the turn are drawn as the same chips the composer showed a moment before it
/// was sent, rather than as the list of paths the agent was handed. The agent needs paths in the
/// text and always will, but the reader already knows what they attached and a scratch path under
/// `.bloom/attachments` tells them nothing they did not know. See `AttachmentTrailer` for the one
/// place that format is written and read.
struct UserTurnRowView: View {
    var text: String
    /// The files this turn carried, worktree relative, in the order they were attached.
    var attachments: [String] = []
    /// Which worktree those paths are relative to, and which review the chips open into.
    var workspace: Workspace
    var maxWidth: CGFloat

    @Environment(AppModel.self) private var app

    /// How much of the pane a user turn always leaves empty on its left, so it reads as one side of
    /// a conversation even when it is short.
    private static let inset: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: Self.inset)

            bubble
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

    /// The words and then the files, which is the order they were written in and the order the
    /// composer showed them in, except that up there the chips sat above the text because that is
    /// where the row of them lives. Here the sentence comes first: it is what the turn is about.
    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.block) {
            // A prompt of nothing but attachments is a turn in its own right, and an empty `Text`
            // above the chips would put a blank line inside the bubble.
            if !text.isEmpty {
                Text(text)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(TranscriptLayout.proseLeading)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !attachments.isEmpty {
                // The composer's own flow layout, so a turn carrying eight files wraps them the
                // same way the box did rather than pushing the bubble off the pane.
                ChipFlow(spacing: Metrics.spacingSmall, lineSpacing: Metrics.spacingSmall) {
                    ForEach(attachments, id: \.self) { path in
                        AttachmentChip(
                            attachment: .sent(path: path),
                            worktree: workspace.path,
                            onOpen: { open(path) }
                        )
                    }
                }
            }
        }
    }

    /// A chip opens where every other file in Bloom opens, which is the review tab, and it is the
    /// same door the composer's chips use. The model is looked up rather than passed down: the
    /// transcript is handed a session, not a workspace model, and `existingModel` only reads.
    private func open(_ path: String) {
        guard let model = app.existingModel(for: workspace.id) else { return }
        FileReview.open(path: path, in: model)
    }
}
