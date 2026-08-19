import SwiftUI
import BloomCore

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var renamingID: String?
    /// Which workspace's strip has finished arriving, so the first draw of a workspace is not
    /// animated. Switching workspace replaces every id in the strip at once, and without this the
    /// selection would fly in from wherever the previous workspace happened to have it.
    @State private var settledWorkspaceID: String?
    @Namespace private var selection

    private var tabs: CenterTabStore { .shared }

    private var toolTabs: [CenterTab] {
        tabs.tabs(for: model.workspace.id)
    }

    private var panes: CenterPaneStore { .shared }

    /// What the pane the user is in is showing. That is what the strip marks, because with the
    /// column split there is no single selection: a tab is either in the pane you are working in
    /// or it is not.
    private var focused: CenterPaneContent? {
        panes.content(of: panes.focusedPane(in: model.workspace.id), in: model)
    }

    var body: some View {
        TabStrip(pane: Self.pane) {
            HStack(spacing: 0) {
                ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 {
                        TabStripSeparator(
                            isHidden: isSelected(model.sessions[index - 1]) || isSelected(session)
                        )
                    }
                    sessionTab(session)
                }

                ForEach(Array(toolTabs.enumerated()), id: \.element.id) { index, tab in
                    if index > 0 || !model.sessions.isEmpty {
                        TabStripSeparator(
                            isHidden: isSelected(before: tab, at: index) || isSelected(tab)
                        )
                    }
                    toolTab(tab)
                }
            }
            // Two values, not one, because they are two different pieces of news and each of them
            // has to be able to arrive on its own. `order` covers opening, closing and dragging a
            // tab; `focused` covers the selection moving. Keying the animation to a value rather
            // than wrapping every mutation in `withAnimation` is what lets the asynchronous ones
            // animate at all: a session is closed and reordered through an actor, so by the time
            // the array changes the call that asked for it is long gone.
            //
            // It also decides, correctly and for free, what must NOT animate. Typing in the rename
            // field changes neither value, so the field cannot creep as the title grows. A busy
            // session's close is refused by a modal until the user answers, and the id only leaves
            // the array once they have said yes, so nothing slides out from under the question.
            .animation(motion, value: order)
            .animation(motion, value: focused)
        } trailing: {
            TabStripSeparator()

            newTabMenu

            TabStripSeparator()

            inspectorToggle
        }
        .background { shortcuts }
        .task(id: model.workspace.id) {
            settledWorkspaceID = nil
            tabs.load(workspaceID: model.workspace.id)
            // One frame is not enough: the sessions arrive from the store after this view first
            // draws, and animating that first fill would slide a whole strip in from the left.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            settledWorkspaceID = model.workspace.id
        }
    }

    /// The centre column opens onto the reading ground, which settles both what a selected tab is
    /// filled with and how far the track under it is sunk. See `TabPane`, which carries the
    /// measurements that used to live here.
    private static let pane = TabPane.content

    // MARK: - Motion

    /// `Motion.pane`, not a curve of this strip's own. It is the one movement the window has, it
    /// is short and it does not overshoot, and a tab highlight that travelled at a different speed
    /// from the inspector it sits beside would read as a second app's idea of how fast things go.
    ///
    /// Nothing moves under Reduce Motion, and nothing moves while a workspace is still arriving.
    /// The setting is dropped rather than slowed, matching every other call site: it is about
    /// movement, not about speed, and the strip says everything it says without any.
    private var motion: Animation? {
        guard !reduceMotion, settledWorkspaceID == model.workspace.id else { return nil }
        return Motion.pane
    }

    /// Every tab in the strip, in the order it is drawn. Identity and order only: a title that
    /// changes must not make the strip move.
    private var order: [String] {
        model.sessions.map(\.id) + toolTabs.map(\.id)
    }

    private func isSelected(_ session: Session) -> Bool {
        focused == .chat(session.id)
    }

    private func isSelected(_ tab: CenterTab) -> Bool {
        focused == .tool(tab.id)
    }

    /// Whether whatever sits immediately before this tool tab is the selected one, which is the
    /// last chat when the tool tabs start and the previous tool tab otherwise.
    private func isSelected(before tab: CenterTab, at index: Int) -> Bool {
        if index == 0 {
            return model.sessions.last.map(isSelected) ?? false
        }
        return isSelected(toolTabs[index - 1])
    }

    // MARK: - Tabs

    private func sessionTab(_ session: Session) -> some View {
        SessionTabView(
            session: session,
            isActive: isSelected(session),
            isRunning: model.isRunning(session),
            isRenaming: renamingID == session.id,
            canClose: model.sessions.count > 1,
            onSelect: { select(session) },
            onStartRename: { renamingID = session.id },
            onCommitRename: { commitRename(session, to: $0) },
            onCancelRename: { renamingID = nil },
            onClose: { close(session) },
            onSplitRight: { split(.chat(session.id), axis: .horizontal) },
            onSplitDown: { split(.chat(session.id), axis: .vertical) },
            namespace: selection
        )
        .draggable(session.id)
        .dropDestination(for: String.self) { items, _ in move(items.first, before: session) }
    }

    private func toolTab(_ tab: CenterTab) -> some View {
        TabItemView(
            title: tabs.displayTitle(of: tab, in: model),
            icon: tab.icon,
            isActive: isSelected(tab),
            surface: Self.pane.surface,
            isRenaming: renamingID == tab.id,
            editableTitle: tab.title,
            canClose: true,
            canRename: tab.kind != .review,
            closeTitle: closeTitle(for: tab),
            onSelect: { panes.show(.tool(tab.id), in: model) },
            onStartRename: { renamingID = tab.id },
            onCommitRename: {
                renamingID = nil
                tabs.rename(tab, to: $0)
            },
            onCancelRename: { renamingID = nil },
            onClose: { Task { await tabs.close(tab) } },
            onSplitRight: { split(.tool(tab.id), axis: .horizontal) },
            onSplitDown: { split(.tool(tab.id), axis: .vertical) },
            namespace: selection
        )
        .draggable(tab.id)
        .dropDestination(for: String.self) { items, _ in move(items.first, before: tab) }
    }

    private func closeTitle(for tab: CenterTab) -> String {
        switch tab.kind {
        case .terminal: "Close terminal"
        case .browser: "Close browser"
        case .review: "Close the review"
        }
    }

    /// One control for all four kinds, because they differ in what they open and in nothing else.
    /// The shortcuts are shown here and fired from `shortcuts`, for the reason spelled out there.
    private var newTabMenu: some View {
        Menu {
            Button("Chat", systemImage: "bubble.left.and.bubble.right", action: newChat)
                .keyboardShortcut("t", modifiers: .command)
            Button("Terminal", systemImage: "apple.terminal", action: newTerminal)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Browser", systemImage: "globe", action: newBrowser)
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Changes", systemImage: "doc.text") { FileReview.open(in: model) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.changedFiles.isEmpty)
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
            // The same key both ways, because it is one question: show me the change, or give me
            // the conversation back. Shift+Cmd+D is what Conductor binds its own diff view to.
            Button("Show Changes") { FileReview.toggle(in: model) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// Opens a tab beside the one the user asked from, rather than in place of it. The menu item
    /// beside the drag is there for anyone who would rather not drag, and for the keyboard.
    private func split(_ content: CenterPaneContent, axis: SplitAxis) {
        panes.split(model.workspace.id, axis: axis, showing: content)
    }

    private func newChat() {
        Task {
            guard let session = await model.createSession() else { return }
            panes.show(.chat(session.id), in: model)
        }
    }

    /// The shell itself is not started here. `ToolPaneView` settles the environment and the
    /// port first, because both are baked into the process the moment it is forked.
    private func newTerminal() {
        panes.show(.tool(tabs.add(kind: .terminal, workspaceID: model.workspace.id).id), in: model)
    }

    private func newBrowser() {
        Task {
            await preparePort()
            let tab = tabs.add(
                kind: .browser,
                workspaceID: model.workspace.id,
                url: model.port > 0 ? "http://localhost:\(model.port)" : ""
            )
            panes.show(.tool(tab.id), in: model)
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

    // MARK: - Reordering
    //
    // Conversations and tools are two runs of the strip, and a drag stays inside its own run.
    //
    // They are not one list because they are not one kind of thing, and because they are not one
    // store either: a session is a row in SQLite that outlives the launch, a terminal or a browser
    // tab is a line in user defaults that is better lost than migrated. Interleaving them would
    // mean one order spanning both, and a session restored from the database would have no way of
    // knowing where a terminal that no longer exists used to sit. Keeping tools after the
    // conversations also means opening or closing one never shifts a conversation the user was
    // aiming at.
    //
    // The payload is the id rather than a `Transferable` of our own, matching the workspace rows
    // in the sidebar. Anything else dropped on a tab, including text from another app, fails the
    // membership check below and the drop is refused.

    private func move(_ draggedID: String?, before session: Session) -> Bool {
        guard let draggedID, draggedID != session.id,
              let moved = model.sessions.first(where: { $0.id == draggedID }),
              let index = model.sessions.firstIndex(where: { $0.id == session.id })
        else { return false }

        Task { await model.reorderSession(moved, to: index) }
        return true
    }

    private func move(_ draggedID: String?, before tab: CenterTab) -> Bool {
        guard let draggedID, draggedID != tab.id,
              let moved = toolTabs.first(where: { $0.id == draggedID }),
              let index = toolTabs.firstIndex(where: { $0.id == tab.id })
        else { return false }

        tabs.move(moved, to: index)
        return true
    }

    // MARK: - Actions

    /// The workspace still has one active session, because the toolbar, the inspector and the
    /// pull request button all speak about one conversation. Showing a chat in a pane is what
    /// decides which one that is.
    private func select(_ session: Session) {
        panes.show(.chat(session.id), in: model)
        model.activeSessionID = session.id
    }

    private func close(_ session: Session) {
        guard CloseSessionAlert.allowsClosing(session, in: model) else { return }
        Task {
            await model.closeSession(session)
            panes.forget(.chat(session.id), in: model.workspace.id)
        }
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
