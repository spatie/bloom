import SwiftUI
import BloomCore
import BloomClient

/// Native Markdown editing over the same durable draft and serial writer used on iOS.
struct NotesPaneView<Model: WorkspacePaneModel>: View {
    @Bindable var model: Model
    @State private var session: WorkspaceNoteSession?
    @State private var write: WorkspaceNoteSession.Write?
    @State private var openingError: String?
    @FocusState private var isEditing: Bool

    private var scope: String { model.paneStores.identity }
    private var identity: String { scope + "/" + model.workspace.id.rawValue }

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    NotesPage(
                        text: Binding(get: { session.text }, set: { text in
                            if let write { session.edit(text, using: write) }
                        }),
                        isEditing: $isEditing,
                        workspaceID: model.workspace.id,
                        workspaceName: model.workspace.name,
                        hasLoaded: session.canEdit,
                        couldNotLoad: session.loadError != nil && !session.canEdit,
                        couldNotSave: session.saveError != nil || session.draftError != nil,
                        hasChanges: session.hasChanges,
                        isSaving: session.isSaving,
                        saveFailure: session.draftError ?? session.saveError,
                        onRetryLoad: { Task { await load(session) } },
                        onRetrySave: saveNow
                    )

                }
            } else if let openingError {
                ContentUnavailableView("Notes could not be opened", systemImage: "note.text", description: Text(openingError))
            } else { LoadingView("Loading notes") }
        }
        .task(id: identity) {
            saveNow()
            do {
                let model = model
                let session = try MacWorkspaceNoteDrafts.store.session(scope: scope, workspaceID: model.workspace.id)
                self.session = session
                write = { body in try await model.writeNote(body) }
                openingError = nil
                await session.load { try await model.readNote() }
                if !Task.isCancelled, session.canEdit { isEditing = true }
            } catch { openingError = error.localizedDescription }
        }
        .onChange(of: isEditing) { _, editing in if !editing { saveNow() } }
        .focusedValue(\.isTypingProse, isEditing)
        .onDisappear(perform: saveNow)
    }

    private func load(_ session: WorkspaceNoteSession) async {
        await session.load { try await model.readNote() }
    }

    private func saveNow() { if let session, let write { session.save(using: write) } }
}

@MainActor
private enum MacWorkspaceNoteDrafts {
    static let store = WorkspaceNoteDraftStore(file: Store.defaultDirectory.appendingPathComponent("Notes/drafts.json"))
}
