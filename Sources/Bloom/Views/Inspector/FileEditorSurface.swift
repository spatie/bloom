import SwiftUI
import BloomCore

/// The file editor, save status and discard flow, shared by local and remote file adapters.
struct FileEditorSurface: View {
    @Binding var text: String
    var path: String
    var status: FileEditSession.Status
    var hasContents: Bool
    var isDirty: Bool
    var isSaving = false
    var onSave: () -> Void
    var onReload: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isConfirmingReload = false
    private var filename: String { (path as NSString).lastPathComponent }

    var body: some View {
        Group {
            switch status {
            case .loading:
                LoadingView("Reading the file")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .unavailable(reason):
                EmptyStateView(
                    glyph: "doc.badge.gearshape",
                    title: "Cannot edit this file",
                    message: reason
                )
            default:
                editor
            }
        }
        .background(Palette.surface)
    }

    @ViewBuilder
    private var editor: some View {
        if hasContents {
            VStack(spacing: 0) {
                SourceEditor(
                    text: $text,
                    language: Language.detect(path: path),
                    colorScheme: colorScheme
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Hairline()
                footer
            }
        } else {
            LoadingView("Reading the file")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: InspectorLayout.gap) {
            statusLabel

            Spacer(minLength: InspectorLayout.tight)

            if isDirty {
                Button("Discard") { isConfirmingReload = true }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Throw away your unsaved edits and read the file again")
            }

            Button("Save", action: onSave)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || isSaving)
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
        .background(Palette.surfaceSunken)
        .confirmationDialog(
            "Discard your edits to \(filename)?",
            isPresented: $isConfirmingReload,
            titleVisibility: .visible
        ) {
            Button("Discard and reload", role: .destructive) {
                onReload()
            }
            // Escape keeps the edits. See the archive confirmation in `RootView` for why no
            // cancel button in this app carries `.keyboardShortcut(.defaultAction)`.
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The file on disk replaces what you typed. There is no undo for this.")
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(Typo.caption)
                .foregroundStyle(Palette.negative)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        case .saved where !isDirty:
            Label("Saved", systemImage: "checkmark.circle")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        default:
            Text(isDirty ? "Unsaved changes" : "No changes")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }
}
