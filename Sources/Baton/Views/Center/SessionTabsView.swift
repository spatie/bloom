import SwiftUI
import BatonCore

/// The strip of parallel conversations inside one workspace.
///
/// Sessions share a worktree but not a context window, which is the whole point: a question about
/// the code should not cost the turn that is halfway through writing it. The strip disappears when
/// there is only one untouched session, because a lone tab is chrome that explains nothing.
struct SessionTabsView: View {
    @Bindable var model: WorkspaceModel

    @Environment(AppModel.self) private var app

    @State private var renamingID: String?

    var body: some View {
        if !isHidden {
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                            // A rule between neighbours, which is what makes a row of labels read
                            // as tabs at all once the selected one is no longer a coloured pill.
                            if index > 0 { Hairline(axis: .vertical) }

                            SessionTabView(
                                session: session,
                                isActive: session.id == model.activeSession?.id,
                                isRunning: isRunning(session),
                                isRenaming: renamingID == session.id,
                                canClose: model.sessions.count > 1,
                                onSelect: { select(session) },
                                onStartRename: { startRename(session) },
                                onCommitRename: { commitRename(session, to: $0) },
                                onCancelRename: cancelRename,
                                onClose: { close(session) }
                            )
                        }
                    }
                }
                .scrollIndicators(.never)

                Hairline(axis: .vertical)

                Button(action: createSession) {
                    Label("New session", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(Typo.labelEmphasis)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: Metrics.barHeight, height: Metrics.barHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("New session in this workspace")
            }
            .frame(height: Metrics.barHeight)
            .headerMaterial()
            .overlay(alignment: .bottom) { Hairline() }
        }
    }

    // MARK: - Rules

    /// Hidden whenever there is a single session.
    ///
    /// A tab strip exists to switch between things. With one session there is nothing to switch to,
    /// and the title it would show is derived from the opening prompt, so it duplicates the
    /// workspace name already in the toolbar, truncated to whatever the tab happens to be wide. One
    /// tab reading "Show me the" under a toolbar reading the whole sentence is worse than no tab.
    private var isHidden: Bool {
        model.sessions.count <= 1
    }

    /// The active session's live state comes from its transcript. The others fall back to what the
    /// store last recorded, because asking for their transcript here would build a model for every
    /// session the moment the strip drew.
    private func isRunning(_ session: Session) -> Bool {
        if session.id == model.activeSession?.id {
            return model.activeTranscript?.isRunning ?? false
        }
        return session.state == .running
    }

    // MARK: - Actions

    private func createSession() {
        Task { await model.createSession() }
    }

    private func select(_ session: Session) {
        model.activeSessionID = session.id
    }

    private func startRename(_ session: Session) {
        renamingID = session.id
    }

    private func cancelRename() {
        renamingID = nil
    }

    private func close(_ session: Session) {
        Task { await model.closeSession(session) }
    }

    private func commitRename(_ session: Session, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingID = nil
        guard !title.isEmpty, title != session.title, let store = app.store else { return }

        let updated = session.with { $0.title = title }
        if let index = model.sessions.firstIndex(where: { $0.id == session.id }) {
            model.sessions[index] = updated
        }
        Task {
            _ = try? await store.upsert(updated)
            await model.reloadSessions()
        }
    }
}
