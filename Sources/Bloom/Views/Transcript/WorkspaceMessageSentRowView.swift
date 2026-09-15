import SwiftUI
import BloomCore

/// A `workspace_say` call, drawn in the chat that made it as the message it sent.
///
/// **On the left, with this agent's own output**, because this agent said it: the right hand side
/// is for what is said TO the agent. The same Starfish bubble the receiving chat draws, mirrored so
/// its tail points at this side of the pane, and headed "To" the workspace.
///
/// **No delivery state, and it used to have three.** Queued with a spinner and Cancel, delivered
/// with a tick and the time, or cancelled. Reported as not needed, and it was not: nothing else in
/// the transcript says when it was delivered, and an agent's message going into a queue is not
/// something the owner sits and watches. Cancelling from here went with it; the receiving chat's
/// own Delete still takes a queued message back out. What is left is the one state that changes
/// what the bubble means, which is that it never went.
///
/// **Cut to three lines.** A brief for another workspace can run to a dozen paragraphs, and here it
/// is a record of something this agent did, sitting between its own work. The receiving chat is
/// where it is read, so it is drawn whole there and shortened here, with a way to open it.
struct WorkspaceMessageSentRowView: View {
    var record: WorkspaceSayRecord

    @Environment(AppModel.self) private var app
    @Environment(\.transcriptBubbleWidth) private var bubbleWidth

    @State private var state: WorkspaceMessage.State?
    @State private var isExpanded = false
    /// Whether the message is longer than the cut. Measured only while it is cut, so opening it does
    /// not make the control that closes it disappear.
    @State private var isLong = false
    @State private var drawnHeight: CGFloat = 0
    @State private var wholeHeight: CGFloat = 0

    /// Enough for a short message to be whole and a long one to say what it is about.
    private static let collapsedLines = 3

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
                WorkspaceMessageOrigin(end: record.target, direction: .to)
                bubble
                caption
            }

            Spacer(minLength: UserTurnRowView.inset)
        }
        .padding(.vertical, TranscriptLayout.inset)
        .task(id: app.workspaceMessagesRevision) {
            let read = await app.workspaceMessage(id: record.messageID)?.state
            guard !Task.isCancelled, read != state else { return }
            state = read
        }
    }

    private var bubble: some View {
        CappedWidth(width: bubbleWidth?.cap ?? UserTurnRowView.uncappedFallback) {
            Text(record.text)
                .font(Typo.body)
                .foregroundStyle(Palette.workspaceMessageInk)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : Self.collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    drawnHeight = $0
                    measure()
                }
                .background(alignment: .topLeading) { ruler }
                .padding(UserTurnRowView.padding)
        }
        .padding(.bottom, OutgoingBubbleShape.tailDrop)
        .background {
            OutgoingBubbleShape(cornerRadius: UserTurnRowView.corner)
                .fill(Palette.workspaceMessageFill)
                .scaleEffect(x: -1, y: 1)
        }
    }

    /// The same text with no line limit, at the width the cut one was given, so the two heights say
    /// whether anything was cut. SwiftUI never reports that itself. A background is sized to the
    /// content it is behind, and `fixedSize` vertically lets the ruler run past it rather than be
    /// clamped, which is the same arrangement `TruncationProbe` uses for a single line.
    @ViewBuilder
    private var ruler: some View {
        if !isExpanded {
            Text(record.text)
                .font(Typo.body)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    wholeHeight = $0
                    measure()
                }
        }
    }

    /// Half a point of slack, because the two heights come from two layouts of the same string.
    private func measure() {
        guard !isExpanded, drawnHeight > 0, wholeHeight > 0 else { return }
        let long = wholeHeight > drawnHeight + 0.5
        if long != isLong { isLong = long }
    }

    @ViewBuilder
    private var caption: some View {
        if state == .cancelled || isLong {
            HStack(spacing: Metrics.gutter) {
                if state == .cancelled {
                    Text("Cancelled before it was delivered").foregroundStyle(Palette.textTertiary)
                }
                if isLong {
                    Button(isExpanded ? "Show less" : "Show all") { isExpanded.toggle() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.textTertiary)
                        .pointerStyle(.link)
                }
            }
            .font(Typo.caption)
        }
    }
}
