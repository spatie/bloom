import SwiftUI
import BloomCore

/// An overlay rather than another pane: the parent remains visible and its runner stays owned
/// by the workspace. The child uses the ordinary transcript and composer, including approvals.
struct SideConversationView: View {
    var parent: TranscriptModel
    @Bindable var state: SideConversationState
    var model: WorkspaceModel
    @State private var room = ComposerRoom()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let snapshot = state.snapshot {
                Label {
                    Text("Recent context from \(snapshot.title) at \(snapshot.capturedAt.formatted(date: .omitted, time: .shortened))")
                        .lineLimit(1)
                } icon: { Image(systemName: "arrow.triangle.branch") }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Palette.surfaceSunken)
            }
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
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(Palette.border, lineWidth: Metrics.outline)
        }
        .elevation(.lifted)
        .focusedValue(\.composerTranscript, state.transcript)
        .onExitCommand { model.dismissSideConversation(from: parent) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side conversation")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Side conversation", systemImage: "arrow.turn.down.right")
                .font(.callout.weight(.semibold))
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
        .padding(14)
    }

    private func conversation(_ child: TranscriptModel) -> some View {
        TranscriptView(
            transcript: child,
            emptyState: TranscriptEmptyState(
                glyph: "arrow.turn.down.right", title: "What’s on your mind?",
                message: "Ask a follow-up about this work. The main conversation continues independently."
            )
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
