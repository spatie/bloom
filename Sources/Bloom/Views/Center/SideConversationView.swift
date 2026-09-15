import SwiftUI
import BloomCore

/// An overlay rather than another pane: the parent remains visible and its runner stays owned
/// by the workspace. The child uses the ordinary transcript and composer, including approvals.
///
/// Dressed as the quick prompt popover beside its button, glass with a tail pointing down at the
/// footer, because it opens from the same row of controls and a flat card pinned to the corner
/// read as a different app. It is not a popover; `ChatPaneView` says why.
struct SideConversationView: View {
    var parent: TranscriptModel
    @Bindable var state: SideConversationState
    var model: WorkspaceModel
    /// Where the tail meets the card, from its leading edge, or nil for a card with no tail. See
    /// `SideConversationPlacement`.
    var tailX: CGFloat?
    @State private var room = ComposerRoom()

    /// The composer's own radius rather than `Metrics.corner`. The card hangs over the top of the
    /// composer, and a system popover on macOS 26 is drawn far rounder than a six point card, so
    /// the one existing large radius in the same column is the one that makes the two read as a
    /// family.
    static let corner = ComposerLayout.corner

    private var shape: SideConversationCardShape {
        SideConversationCardShape(
            cornerRadius: Self.corner,
            tailX: tailX,
            tailSize: SideConversationPlacement.tailSize
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = state.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Palette.negative)
                    .textSelection(.enabled)
                    .padding(12)
            }
            if let child = state.transcript {
                conversation(child)
            } else {
                VStack(spacing: 12) {
                    if state.isOpening { ProgressView().controlSize(.small) }
                    Text(state.isOpening ? "Opening side conversation…" : "Could not open side conversation")
                        .font(.callout)
                    if !state.isOpening {
                        Button("Try again") { model.openSideConversation(from: parent) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        // The content stops at the body's corners; the tail below it is glass and nothing else.
        .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        .padding(.bottom, tailX == nil ? 0 : SideConversationPlacement.tailSize.height)
        // `.regular`, as `MenuPanel` argues: this opens over the transcript, where a user bubble
        // is an accent fill, and clear glass would carry that colour through the card.
        .glassEffect(.regular, in: shape)
        // Drawn rather than left to the glass, for `MenuPanel`'s reason: once Reduce Transparency
        // has made the material opaque, the rim is what still says where the card ends.
        .overlay {
            shape.stroke(Palette.border, lineWidth: Metrics.outline)
        }
        .elevation(.lifted)
        .focusedValue(\.composerTranscript, state.transcript)
        .onExitCommand { model.dismissSideConversation(from: parent) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side conversation")
    }

    /// The title with where its context came from underneath, rather than a sunken band of its
    /// own under a rule. A popover's header is a line of text, and the band made the top of the
    /// card three stacked surfaces before the conversation began.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                Label("Side conversation", systemImage: "arrow.turn.down.right")
                    .font(.callout.weight(.semibold))
                if let snapshot = state.snapshot {
                    Text("Recent context from \(snapshot.title) at \(snapshot.capturedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("Keep and start new") { model.openSideConversation(from: parent, fresh: true) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(state.isOpening || state.transcript == nil)
            .help("Start a new side conversation with the latest context")
            .accessibilityLabel("Side conversation options")
            Button {
                model.dismissSideConversation(from: parent)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss side conversation (Escape)")
            .accessibilityLabel("Dismiss side conversation")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func conversation(_ child: TranscriptModel) -> some View {
        TranscriptView(
            transcript: child,
            emptyState: TranscriptEmptyState(
                glyph: "arrow.turn.down.right", title: "What’s on your mind?",
                message: "Ask a follow-up about this work. The main conversation continues independently."
            ),
            drawsBackground: false
        )
        .environment(\.composerRoom, room)
        .overlay(alignment: .bottom) {
            ComposerView(
                transcript: child, model: model, room: room,
                placeholder: "Ask a side question…",
                onDismiss: { model.dismissSideConversation(from: parent) },
                includesReviewComments: false
            )
        }
        .onGeometryChange(for: CGFloat.self) { PaneMeasure.room($0.size.height) } action: {
            room.height = $0
        }
        .id(child.session.id)
    }

    private var footer: some View {
        HStack {
            Label(
                parent.isRunning ? "Main agent working" : "Main agent idle",
                systemImage: parent.isRunning ? "circle.dotted" : "checkmark.circle"
            )
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                model.keepSideConversation(from: parent)
            } label: {
                Label("Keep as chat", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .disabled(state.isOpening || state.transcript == nil)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
