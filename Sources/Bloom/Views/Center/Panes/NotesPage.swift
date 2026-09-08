import SwiftUI
import BloomCore

/// The notes' writing surface. Persistence stays with NotesPaneView.
struct NotesPage: View {
    @Binding var text: String
    var isEditing: FocusState<Bool>.Binding
    var workspaceID: WorkspaceID
    var workspaceName: String
    var hasLoaded: Bool
    var couldNotLoad: Bool
    var couldNotSave: Bool
    var hasChanges: Bool
    var onRetryLoad: () -> Void
    var onRetrySave: () -> Void

    @State private var commands = NotesFormattingCommands()
    @State private var showsSource = false

    static let textPadding: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Self.textPadding)
                .padding(.top, Metrics.pane)
                .padding(.bottom, Metrics.inset)

            NotesFormattingBar(commands: commands, isEditing: isEditing.wrappedValue, showsSource: $showsSource)
                .disabled(!hasLoaded)
                .padding(.bottom, Metrics.spacingWide)

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

    private var header: some View { heading }

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

    private var editor: some View {
        NotesMarkdownEditor(text: $text, isEditing: isEditing, workspaceID: workspaceID,
                            isEditable: hasLoaded, showsSource: showsSource, commands: commands)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
        }
        .font(Typo.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
