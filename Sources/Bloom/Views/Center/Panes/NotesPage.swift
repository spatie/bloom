import SwiftUI
import BloomCore

/// The notes' writing surface. Persistence and the handoff stay with NotesPaneView.
struct NotesPage: View {
    @Binding var text: String
    var isEditing: FocusState<Bool>.Binding
    var workspaceName: String
    var hasLoaded: Bool
    var couldNotLoad: Bool
    var couldNotSave: Bool
    var hasChanges: Bool
    var onRetryLoad: () -> Void
    var onRetrySave: () -> Void
    var onHandOff: () -> Void

    static let textPadding: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Self.textPadding)
                .padding(.top, Metrics.pane)
                .padding(.bottom, Metrics.pane)

            editor

            footer
                .padding(.horizontal, Self.textPadding)
                .padding(.vertical, Metrics.inset)
        }
        .frame(maxWidth: TranscriptLayout.conversationMeasure)
        .padding(.horizontal, Metrics.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.surface)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Metrics.pane) {
                heading
                Spacer(minLength: Metrics.spacingWide)
                handoffButton
            }
            VStack(alignment: .leading, spacing: Metrics.inset) {
                heading
                handoffButton
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text("Notes")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(workspaceName)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .help(workspaceName)
        }
    }

    private var handoffButton: some View {
        Button("Send to composer", systemImage: "arrow.turn.down.left", action: onHandOff)
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(!hasLoaded || WorkspaceNote.handoff(text) == nil)
            .help("Adds these notes to the conversation's draft for you to review and send.")
    }

    private var editor: some View {
        TextEditor(text: $text)
            .focused(isEditing)
            // Keep the floating Writing Tools affordance out of the neighbouring pane.
            .writingToolsBehavior(.disabled)
            .font(Typo.body)
            .lineSpacing(5)
            .foregroundStyle(Palette.textPrimary)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(!hasLoaded)
            .accessibilityLabel("Workspace notes")
            .overlay(alignment: .topLeading) { placeholder }
    }

    @ViewBuilder
    private var placeholder: some View {
        if couldNotLoad {
            VStack(alignment: .leading, spacing: Metrics.inset) {
                Text(WorkspaceNote.unreadable)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                Button("Try again", action: onRetryLoad)
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, Self.textPadding)
        } else if hasLoaded, text.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                Text("Start writing…")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPlaceholder)
                Text("Ideas, decisions and reminders for this workspace.")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Match the native editor's first glyph, including its text-container padding.
            .padding(.horizontal, Self.textPadding)
            .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            if couldNotSave {
                Text(WorkspaceNote.unwritable)
                    .foregroundStyle(Palette.warning)
                Button("Try saving again", action: onRetrySave)
                    .buttonStyle(.borderless)
            } else if couldNotLoad {
                Text("Notes could not be loaded")
                    .foregroundStyle(Palette.textSecondary)
            } else if !hasLoaded {
                Text("Loading notes…")
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Label(hasChanges ? "Saving…" : "Saved with this workspace",
                      systemImage: hasChanges ? "ellipsis" : "checkmark")
                    .foregroundStyle(Palette.textSecondary)
                Text("Notes are not sent to the agent automatically.")
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .font(Typo.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
