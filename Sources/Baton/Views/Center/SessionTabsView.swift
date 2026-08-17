import SwiftUI
import BatonCore

/// The strip of parallel conversations inside one workspace.
///
/// Sessions share a worktree but not a context window, which is the whole point: a question about
/// the code should not cost the turn that is halfway through writing it. The strip disappears
/// when there is only one untouched session, because a lone tab is chrome that explains nothing.
struct SessionTabsView: View {
    @Bindable var model: WorkspaceModel

    @Environment(AppModel.self) private var app

    @State private var hoveredID: String?
    @State private var renamingID: String?
    @State private var renameText = ""
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        if !isHidden {
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(model.sessions) { session in
                            tab(session)
                        }
                    }
                }
                .scrollIndicators(.never)

                Button {
                    Task { await model.createSession() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New session in this workspace")
                .padding(.trailing, 6)
            }
            .frame(height: 30)
            .background(Palette.surface)
            .overlay(alignment: .bottom) { Hairline() }
        }
    }

    // MARK: - Tabs

    private func tab(_ session: Session) -> some View {
        let isActive = session.id == model.activeSession?.id
        let isHovered = session.id == hoveredID

        return HStack(spacing: 5) {
            if isRunning(session) {
                ActivityDot(isActive: true)
            }

            if renamingID == session.id {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(Typo.label)
                    .focused($isRenameFocused)
                    .frame(width: 120)
                    .onSubmit { commitRename(session) }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(session.title.isEmpty ? "Untitled" : session.title)
                    .font(isActive ? Typo.labelEmphasis : Typo.label)
                    .foregroundStyle(isActive ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
            }

            // The close button only appears on hover, so a row of tabs is not a row of crosses.
            if isHovered, model.sessions.count > 1 {
                Button {
                    Task { await model.closeSession(session) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close session")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isHovered && !isActive ? Palette.hover : .clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? Palette.accent : .clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .onEnded { startRename(session) }
                .exclusively(
                    before: TapGesture().onEnded { model.activeSessionID = session.id }
                )
        )
        .onHover { hovering in
            hoveredID = hovering ? session.id : (hoveredID == session.id ? nil : hoveredID)
        }
        .contextMenu {
            Button("Rename") { startRename(session) }
            Button("Close") { Task { await model.closeSession(session) } }
                .disabled(model.sessions.count <= 1)
        }
    }

    // MARK: - Rules

    /// A workspace starts with one session nobody named. Showing a tab strip for it would only
    /// tell the user something they can already see.
    private var isHidden: Bool {
        guard model.sessions.count <= 1 else { return false }
        guard let session = model.sessions.first else { return true }
        return Self.isUnnamed(session)
    }

    static func isUnnamed(_ session: Session) -> Bool {
        let title = session.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty || title == "New session"
    }

    /// The active session's live state comes from its transcript. The others fall back to what
    /// the store last recorded, because asking for their transcript here would build a model for
    /// every session the moment the strip drew.
    private func isRunning(_ session: Session) -> Bool {
        if session.id == model.activeSession?.id {
            return model.activeTranscript?.isRunning ?? false
        }
        return session.state == .running
    }

    // MARK: - Renaming

    private func startRename(_ session: Session) {
        renameText = session.title
        renamingID = session.id
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            guard renamingID == session.id else { return }
            isRenameFocused = true
        }
    }

    private func commitRename(_ session: Session) {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
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
