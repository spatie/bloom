import SwiftUI
import BloomCore

/// Edit mode: the file itself, editable, with the save guard underneath it.
///
/// The bar along the bottom is not decoration. It is the only place the user finds out that a
/// save was refused because the agent had already rewritten the file, and the only way back from
/// that: reload, look at what the agent did, and redo the edit on top of it.
struct FileEditPane: View {
    let model: WorkspaceModel
    let file: ChangedFile
    let session: FileEditSession

    @Environment(\.colorScheme) private var colorScheme

    @State private var isConfirmingReload = false

    private var path: String {
        (model.workspace.path as NSString).appendingPathComponent(file.path)
    }

    private var isDirty: Bool { session.isDirty(path) }

    var body: some View {
        Group {
            switch session.status(for: path) {
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
        .task(id: path) { await session.load(path: path) }
    }

    @ViewBuilder
    private var editor: some View {
        if session.draft(for: path) != nil {
            VStack(spacing: 0) {
                SourceEditor(
                    text: session.binding(for: path),
                    language: Language.detect(path: file.path),
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

            Button("Save", action: save)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
        .background(Palette.surfaceSunken)
        .confirmationDialog(
            "Discard your edits to \(file.filename)?",
            isPresented: $isConfirmingReload,
            titleVisibility: .visible
        ) {
            Button("Discard and reload", role: .destructive) {
                Task { await session.reload(path: path) }
            }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The file on disk replaces what you typed. There is no undo for this.")
        }
    }

    /// A save changes the worktree, so the file list's counts and the diff behind this pane are
    /// both stale the moment it lands.
    private func save() {
        Task {
            await session.save(path: path)
            guard case .saved = session.status(for: path) else { return }
            await model.refreshChanges()
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch session.status(for: path) {
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
