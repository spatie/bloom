import SwiftUI
import BloomCore

/// Edit mode: the file itself, editable, with the save guard underneath it.
///
/// The bar along the bottom is not decoration. It is the only place the user finds out that a
/// save was refused because the agent had already rewritten the file, and the only way back from
/// that: reload, look at what the agent did, and redo the edit on top of it.
///
/// A path rather than a `ChangedFile`, because the two ways into a file are the diff of one the
/// agent touched and the worktree tree, and the tree opens files git has never heard of. Editing
/// is a question about bytes on disk either way, so the pane only ever needed the path.
struct FileEditPane: View {
    let model: WorkspaceModel
    /// Relative to the workspace's worktree, the way every path in the inspector is.
    let path: String
    let session: FileEditSession
    /// Called after a save lands, for a pane whose other half is now showing stale text.
    var onSaved: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    @State private var isConfirmingReload = false

    private var absolutePath: String {
        (model.workspace.path as NSString).appendingPathComponent(path)
    }

    private var filename: String { (path as NSString).lastPathComponent }

    private var isDirty: Bool { session.isDirty(absolutePath) }

    var body: some View {
        Group {
            switch session.status(for: absolutePath) {
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
        .task(id: absolutePath) { await session.load(path: absolutePath) }
    }

    @ViewBuilder
    private var editor: some View {
        if session.draft(for: absolutePath) != nil {
            VStack(spacing: 0) {
                SourceEditor(
                    text: session.binding(for: absolutePath),
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

            Button("Save", action: save)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
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
                Task { await session.reload(path: absolutePath) }
            }
            // Escape keeps the edits. See the archive confirmation in `RootView` for why no
            // cancel button in this app carries `.keyboardShortcut(.defaultAction)`.
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The file on disk replaces what you typed. There is no undo for this.")
        }
    }

    /// A save changes the worktree, so the file list's counts and the diff behind this pane are
    /// both stale the moment it lands.
    private func save() {
        Task {
            await session.save(path: absolutePath)
            guard case .saved = session.status(for: absolutePath) else { return }
            await model.refreshChanges()
            onSaved()
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch session.status(for: absolutePath) {
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
