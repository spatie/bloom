import SwiftUI
import BloomCore

/// A message from another workspace, in the chat it was sent to.
///
/// **On the right, with the owner's own turns**, because the right hand side of this transcript
/// means "said to this agent", and this was: the owner's words and another workspace's arrive the
/// same way, as a turn the agent answers.
///
/// **The owner's bubble, in another colour, and nothing more.** Same shape, same measure, same
/// padding and the same tail; what tells the two apart is the Starfish fill and one line above
/// saying who it is from. It was a pale periwinkle plate with a coloured initial, a project and a
/// chat name above, and an "Open" link and a disclosure below, which made it look like a different
/// kind of object rather than the same one from somebody else. See `Palette.workspaceMessage` for
/// why the colour moved.
///
/// Drawn whole, however long. This is what the agent here is answering, so the reader should be
/// able to read all of it; it is the sending chat that shortens it. See
/// `WorkspaceMessageSentRowView`.
///
/// Queued, it is the same bubble unfilled with a dotted edge, which is what the owner's own queued
/// turn looks like, and it can be deleted the way that one can. It cannot be edited or steered:
/// the words are not the owner's to change. See `PendingTurnRowView`.
struct WorkspaceMessageRowView: View {
    var message: CrewMessage
    var isWaiting = false
    /// The queue's one sentence, on the last message waiting. See `PendingTurnRowView.caption`.
    var holdSentence: String?
    var onDelete: () -> Void = {}

    /// Read here for the reason `UserTurnRowView` reads it: a pane narrowing then invalidates the
    /// bubbles and not every tool row.
    @Environment(\.transcriptBubbleWidth) private var bubbleWidth

    @State private var showsEnvelope = false
    @State private var isPointedAt = false

    /// `PendingTurnRowView`'s dots, so both queued bubbles are edged the same way.
    private static let dots = StrokeStyle(lineWidth: Metrics.outline, dash: [2, 3])

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: UserTurnRowView.inset)

            VStack(alignment: .trailing, spacing: TranscriptLayout.tight) {
                WorkspaceMessageOrigin(end: message.route, direction: .from)
                bubble
                caption
                if showsEnvelope { envelope }
            }
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.inset)
        .onHover { isPointedAt = $0 }
    }

    private var bubble: some View {
        CappedWidth(width: bubbleWidth?.cap ?? UserTurnRowView.uncappedFallback) {
            Text(message.text)
                .font(Typo.body)
                .foregroundStyle(isWaiting ? Palette.textSecondary : Palette.workspaceMessageInk)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(UserTurnRowView.padding)
        }
        .padding(.bottom, OutgoingBubbleShape.tailDrop)
        .background {
            if isWaiting {
                OutgoingBubbleShape(cornerRadius: UserTurnRowView.corner)
                    .strokeBorder(Palette.workspaceMessage, style: Self.dots)
            } else {
                OutgoingBubbleShape(cornerRadius: UserTurnRowView.corner)
                    .fill(Palette.workspaceMessageFill)
            }
        }
    }

    @ViewBuilder
    private var caption: some View {
        if isWaiting {
            HStack(spacing: Metrics.gutter) {
                if let holdSentence {
                    Text(holdSentence).foregroundStyle(Palette.textTertiary)
                }
                Button("Delete", action: onDelete)
                    .buttonStyle(.plain)
                    .foregroundStyle(isPointedAt ? Palette.link : Palette.textTertiary)
                    .pointerStyle(.link)
                    .help("Takes this message back out of the queue. It is not sent, and the workspace that sent it is told.")
            }
            .font(Typo.caption)
        } else {
            // What the model was handed, which is the message inside its envelope. Evidence for when
            // an agent does something strange, and nothing a reader needs on the way past, so it
            // appears under the pointer rather than sitting under every message. Faded rather than
            // removed, so nothing below moves when the pointer arrives.
            Button(showsEnvelope ? "Hide full prompt" : "Show full prompt") {
                showsEnvelope.toggle()
            }
            .buttonStyle(.plain)
            .font(Typo.caption)
            .foregroundStyle(Palette.textTertiary)
            .pointerStyle(.link)
            .opacity(isPointedAt || showsEnvelope ? 1 : 0)
        }
    }

    /// The bytes the agent was given, for when it does something strange with them.
    private var envelope: some View {
        Text(message.sent)
            .font(Typo.codeSmall)
            .foregroundStyle(Palette.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: bubbleWidth?.cap ?? UserTurnRowView.uncappedFallback, alignment: .leading)
    }
}
