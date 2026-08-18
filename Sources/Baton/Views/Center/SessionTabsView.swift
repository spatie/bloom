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
                        .font(Typo.captionEmphasis)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: Metrics.rowHeight, height: Metrics.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("New session in this workspace")
                .padding(.trailing, Metrics.corner)
            }
            .frame(height: Metrics.rowHeight)
            .headerMaterial()
            .overlay(alignment: .bottom) { Hairline() }
        }
    }

    // MARK: - Tabs

    private func tab(_ session: Session) -> some View {
        let isActive = session.id == model.activeSession?.id
        let isHovered = session.id == hoveredID

        return HStack(spacing: Metrics.cornerSmall) {
            if isRunning(session) {
                ActivityDot(isActive: true)
            }

            if renamingID == session.id {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(Typo.label)
                    .focused($isRenameFocused)
                    .frame(width: Metrics.sidebarWidth / 2)
                    .onSubmit { commitRename(session) }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(session.title.isEmpty ? "Untitled" : session.title)
                    .font(isActive ? Typo.labelEmphasis : Typo.label)
                    .foregroundStyle(isActive ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
            }

            // Keeping the slot avoids every label moving when the pointer enters a tab.
            if !model.sessions.isEmpty {
                Button {
                    Task { await model.closeSession(session) }
                } label: {
                    Image(systemName: "xmark")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: Metrics.rowHeight / 2, height: Metrics.rowHeight / 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .opacity(isHovered && model.sessions.count > 1 ? 1 : 0)
                .allowsHitTesting(isHovered && model.sessions.count > 1)
                .help("Close session")
            }
        }
        .padding(.horizontal, Metrics.corner)
        .frame(height: Metrics.rowHeight)
        .background(
            isActive ? Palette.selected : (isHovered ? Palette.hover : .clear),
            in: Capsule()
        )
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

    /// Hidden whenever there is a single session.
    ///
    /// A tab strip exists to switch between things. With one session there is nothing to switch
    /// to, and the title it would show is derived from the opening prompt, so it duplicates the
    /// workspace name already in the toolbar, truncated to whatever the tab happens to be wide.
    /// One tab reading "Show me the" under a toolbar reading the whole sentence is worse than no
    /// tab at all.
    private var isHidden: Bool {
        model.sessions.count <= 1
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
