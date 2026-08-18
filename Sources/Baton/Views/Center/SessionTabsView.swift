import SwiftUI
import BatonCore

/// The strip of tabs inside one workspace: parallel conversations, shells and pages.
///
/// Sessions share a worktree but not a context window, which is the whole point: a question about
/// the code should not cost the turn that is halfway through writing it. A terminal and a browser
/// share the worktree too, and share the strip for the same reason, so the thing you look at next
/// is always one click along the same row.
///
/// The strip used to disappear while a workspace had a single session, on the grounds that a lone
/// tab repeats the workspace name already in the toolbar. It cannot any more: the `+` that opens a
/// terminal or a browser is part of the strip, and a control nobody can reach is not a control.
struct SessionTabsView: View {
    @Bindable var model: WorkspaceModel

    @Environment(AppModel.self) private var app

    @State private var renamingID: String?

    private var tabs: CenterTabStore { .shared }

    private var toolTabs: [CenterTab] {
        tabs.tabs(for: model.workspace.id)
    }

    /// The tool tab filling the column, if one is. Nil means the conversation is.
    private var activeTool: CenterTab? {
        tabs.selection(for: model.workspace.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                        // A rule between neighbours, which is what makes a row of labels read
                        // as tabs at all once the selected one is no longer a coloured pill.
                        if index > 0 { Hairline(axis: .vertical) }
                        sessionTab(session)
                    }

                    ForEach(Array(toolTabs.enumerated()), id: \.element.id) { index, tab in
                        if index > 0 || !model.sessions.isEmpty { Hairline(axis: .vertical) }
                        toolTab(tab)
                    }
                }
            }
            .scrollIndicators(.never)

            Hairline(axis: .vertical)

            newTabMenu

            Hairline(axis: .vertical)

            inspectorToggle
        }
        .frame(height: Metrics.barHeight)
        .headerMaterial()
        .overlay(alignment: .bottom) { Hairline() }
        .background { shortcuts }
        .task(id: model.workspace.id) { tabs.load(workspaceID: model.workspace.id) }
    }

    // MARK: - Tabs

    private func sessionTab(_ session: Session) -> some View {
        SessionTabView(
            session: session,
            isActive: activeTool == nil && session.id == model.activeSession?.id,
            isRunning: isRunning(session),
            isRenaming: renamingID == session.id,
            canClose: model.sessions.count > 1,
            onSelect: { select(session) },
            onStartRename: { renamingID = session.id },
            onCommitRename: { commitRename(session, to: $0) },
            onCancelRename: { renamingID = nil },
            onClose: { close(session) }
        )
    }

    private func toolTab(_ tab: CenterTab) -> some View {
        CenterTabView(
            title: tab.title,
            icon: tab.icon,
            isActive: activeTool?.id == tab.id,
            isRenaming: renamingID == tab.id,
            editableTitle: tab.title,
            canClose: true,
            closeTitle: tab.kind == .terminal ? "Close terminal" : "Close browser",
            onSelect: { tabs.select(tab, in: model.workspace.id) },
            onStartRename: { renamingID = tab.id },
            onCommitRename: {
                renamingID = nil
                tabs.rename(tab, to: $0)
            },
            onCancelRename: { renamingID = nil },
            onClose: { Task { await tabs.close(tab) } }
        )
    }

    /// One control for all three kinds, because they differ in what they open and in nothing else.
    /// The shortcuts are shown here and fired from `shortcuts`, for the reason spelled out there.
    private var newTabMenu: some View {
        Menu {
            Button("Chat", systemImage: "bubble.left.and.bubble.right", action: newChat)
                .keyboardShortcut("t", modifiers: .command)
            Button("Terminal", systemImage: "apple.terminal", action: newTerminal)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Browser", systemImage: "globe", action: newBrowser)
                .keyboardShortcut("b", modifiers: [.command, .shift])
        } label: {
            Label("New tab", systemImage: "plus")
                .labelStyle(.iconOnly)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Metrics.barHeight, height: Metrics.barHeight)
        .contentShape(Rectangle())
        .help("New tab in this workspace")
    }

    /// The right pane's control, at the trailing end of the strip that borders it.
    ///
    /// It used to be a toolbar item, where it sat above all three columns and so said nothing
    /// about which of them it would move. On the boundary it opens, the target is the thing it is
    /// pointing at.
    ///
    /// `.accessoryBar` rather than the default `.button` fill: on macOS 26 that fill is the
    /// saturated accent colour, and a pane that is on almost all the time then shouts all the
    /// time. `.accessoryBar` marks on with the same neutral raised capsule Finder gives its own
    /// toolbar items, which is legible without being an alarm. It stays a `Toggle` so VoiceOver
    /// still reads it as one and announces the on state without being told to.
    private var inspectorToggle: some View {
        @Bindable var app = app

        return Toggle(isOn: $app.isInspectorVisible) {
            Label("Inspector", systemImage: "sidebar.right")
                .labelStyle(.iconOnly)
                .font(Typo.labelEmphasis)
        }
        .toggleStyle(.button)
        .buttonStyle(.accessoryBar)
        .padding(.horizontal, Metrics.spacing)
        .frame(height: Metrics.barHeight)
        .help(app.isInspectorVisible ? "Hide the changed files" : "Show the changed files")
    }

    /// The menu above shows the shortcuts; it cannot fire them. A `Menu` in a view becomes an
    /// `NSMenu` that hangs off a button, and key equivalents are only offered to the menu bar and
    /// to the view hierarchy, neither of which that menu is in. Buttons are, so these are.
    ///
    /// Cmd+T is missing on purpose: the File menu's New Session already owns it, and a second
    /// registration of the same shortcut in the same window is a coin toss over which one runs.
    private var shortcuts: some View {
        ZStack {
            Button("New Terminal Tab", action: newTerminal)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Browser Tab", action: newBrowser)
                .keyboardShortcut("b", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Rules

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

    private func newChat() {
        tabs.select(nil, in: model.workspace.id)
        Task { await model.createSession() }
    }

    /// The shell itself is not started here. `CenterToolColumn` settles the environment and the
    /// port first, because both are baked into the process the moment it is forked.
    private func newTerminal() {
        tabs.add(kind: .terminal, workspaceID: model.workspace.id)
    }

    private func newBrowser() {
        Task {
            await preparePort()
            tabs.add(
                kind: .browser,
                workspaceID: model.workspace.id,
                url: model.port > 0 ? "http://localhost:\(model.port)" : ""
            )
        }
    }

    /// The workspace's own port, which is what its setup and run scripts were told to bind and so
    /// what its dev server is answering on. Probing for a free block opens sockets, which is why
    /// it happens off the main thread.
    private func preparePort() async {
        guard model.port == 0 else { return }
        let port = await Task.detached { try? PortAllocator.allocate(taken: []) }.value
        model.port = port ?? 0
    }

    private func select(_ session: Session) {
        tabs.select(nil, in: model.workspace.id)
        model.activeSessionID = session.id
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
