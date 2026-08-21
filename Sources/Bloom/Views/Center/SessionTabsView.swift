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

    @State private var renamingID: String?
    /// Which workspace's strip has finished arriving, so the first draw of a workspace is not
    /// animated. Switching workspace replaces every id in the strip at once, and without this the
    /// selection would fly in from wherever the previous workspace happened to have it.
    @Namespace private var selection

    private var tabs: CenterTabStore { .shared }

    private var toolTabs: [CenterTab] {
        tabs.tabs(for: model.workspace.id)
    }

    private var panes: CenterPaneStore { .shared }

    /// What the pane the user is in is showing. That is what the strip marks, because with the
    /// column split there is no single selection: a tab is either in the pane you are working in
    /// or it is not.
    private var focused: PaneContent? {
        panes.content(of: panes.focusedPane(in: model.workspace.id), in: model)
    }

    var body: some View {
        TabStrip(pane: Self.pane, selection: selectedID) {
            HStack(spacing: 0) {
                ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 {
                        TabStripSeparator(
                            isHidden: isSelected(model.sessions[index - 1]) || isSelected(session)
                        )
                    }
                    sessionTab(session)
                        .id(session.id)
                }

                ForEach(Array(toolTabs.enumerated()), id: \.element.id) { index, tab in
                    if index > 0 || !model.sessions.isEmpty {
                        TabStripSeparator(
                            isHidden: isSelected(before: tab, at: index) || isSelected(tab)
                        )
                    }
                    toolTab(tab)
                        .id(tab.id)
                }
            }
        } append: {
            // The rule between the last tab and the `+`, which is the same rule the tabs have
            // between each other and goes the same way: hidden against the selected tab, whose
            // own fill is its edge, and hidden again when there is no tab for it to come after.
            // A workspace whose conversations have all been closed would otherwise open with a
            // hairline standing against the rule down the edge of the pane.
            TabStripSeparator(isHidden: order.last.map(isSelected) ?? true)

            newTabMenu
        } trailing: {
            TabStripSeparator()

            inspectorToggle
        }
        .background { shortcuts }
        .task(id: model.workspace.id) {
            tabs.load(workspaceID: model.workspace.id)
        }
    }

    /// The centre column opens onto the reading ground, which settles both what a selected tab is
    /// filled with and how far the track under it is sunk. See `TabPane`, which carries the
    /// measurements that used to live here.
    private static let pane = TabPane.content

    /// Every tab in the strip, in the order it is drawn. Identity and order only: a title that
    /// changes must not make the strip move.
    private var order: [String] {
        model.sessions.map(\.id.rawValue) + toolTabs.map(\.id)
    }

    /// Whether a tab is the one the pane's leading edge runs through.
    ///
    /// This strip begins at that edge: it has no leading control, so its first tab starts where
    /// the centre column starts. Whichever tab that is drops the line and the corner down that
    /// side and lets the pane's own rule be its edge. See `TabItemView.isAtPaneEdge`.
    ///
    /// Asked of the strip's whole order rather than of either run on its own, because a workspace
    /// whose conversations have all been closed opens with a terminal or a browser first.
    private func isAtPaneEdge(_ id: String) -> Bool {
        order.first == id
    }

    /// Which tab the strip scrolls into view, as a plain id rather than as `PaneContent`.
    ///
    /// Nil when the focused pane is showing something the strip does not have a tab for, which is
    /// the moment after a tab is closed: aiming a scroll at an id that is no longer laid out does
    /// nothing, and this says so rather than relying on that.
    private var selectedID: AnyHashable? {
        switch focused {
        case .chat(let id): model.sessions.contains { $0.id == id } ? AnyHashable(id) : nil
        case .tool(let id): toolTabs.contains { $0.id == id } ? AnyHashable(id) : nil
        case nil: nil
        }
    }

    private func isSelected(_ session: Session) -> Bool {
        focused == .chat(session.id)
    }

    private func isSelected(_ tab: CenterTab) -> Bool {
        focused == .tool(tab.id)
    }

    /// Whether a tab is selected, named by id alone. The strip's two runs answer to two different
    /// cases of `PaneContent`, and `order` has already thrown that distinction away.
    private func isSelected(_ id: String) -> Bool {
        focused == .chat(SessionID(id)) || focused == .tool(id)
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
            agentGlyph: AgentMark.glyph(for: session.agentKind, in: model.sessions),
            isActive: isSelected(session),
            isRunning: model.isRunning(session),
            isAtPaneEdge: isAtPaneEdge(session.id.rawValue),
            isRenaming: renamingID == session.id.rawValue,
            canClose: model.sessions.count > 1,
            onSelect: { select(session) },
            onStartRename: { renamingID = session.id.rawValue },
            onCommitRename: { commitRename(session, to: $0) },
            onCancelRename: { renamingID = nil },
            onClose: { close(session) },
            onSplitRight: { split(.chat(session.id), axis: .horizontal) },
            onSplitDown: { split(.chat(session.id), axis: .vertical) },
            namespace: selection
        )
        .draggable(session.id.rawValue)
        .dropDestination(for: String.self) { items, _ in move(items.first, before: session) }
    }

    private func toolTab(_ tab: CenterTab) -> some View {
        TabItemView(
            title: tabs.displayTitle(of: tab, in: model),
            icon: tab.icon,
            isActive: isSelected(tab),
            isAtPaneEdge: isAtPaneEdge(tab.id),
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
    ///
    /// The first three take their name and their glyph from `PaneKind` rather than spelling them
    /// out, because the pane's split submenus offer the same three and the two lists have to keep
    /// saying the same words.
    private var newTabMenu: some View {
        Menu {
            Button(PaneKind.chat.title, systemImage: PaneKind.chat.symbol, action: newChat)
                .keyboardShortcut("t", modifiers: .command)
            Button(PaneKind.terminal.title, systemImage: PaneKind.terminal.symbol, action: newTerminal)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button(PaneKind.browser.title, systemImage: PaneKind.browser.symbol, action: newBrowser)
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
    private func split(_ content: PaneContent, axis: SplitAxis) {
        panes.split(model.workspace.id, axis: axis, showing: content)
    }

    /// All three go through `NewPane`, which is the same door the pane's split submenus use, so a
    /// tab made from the `+` and a tab made by splitting are the same tab.
    private func newChat() {
        NewPane.open(.chat, in: model) { panes.show($0, in: model) }
    }

    private func newTerminal() {
        NewPane.open(.terminal, in: model) { panes.show($0, in: model) }
    }

    /// The `+` opens a browser on the workspace's own dev server, where a split opens one on
    /// nothing. That is not drift: this item is the one that means "look at what this workspace is
    /// running", and it is the only route that has a port to hand.
    private func newBrowser() {
        Task {
            await preparePort()
            let address = model.port > 0 ? "http://localhost:\(model.port)" : ""
            NewPane.open(.browser, in: model, url: address) { panes.show($0, in: model) }
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
    // membership check below and the drop does nothing.
    //
    // Neither of these answers with a Bool. `dropDestination`'s action used to be asked whether it
    // had taken the drop; the macOS 26 one returns Void and is not asked, so a returned answer is
    // a value nobody reads and the compiler says so.

    private func move(_ draggedID: String?, before session: Session) {
        guard let draggedID, draggedID != session.id.rawValue,
              let moved = model.sessions.first(where: { $0.id.rawValue == draggedID }),
              let index = model.sessions.firstIndex(where: { $0.id == session.id })
        else { return }

        Task { await model.reorderSession(moved, to: index) }
    }

    private func move(_ draggedID: String?, before tab: CenterTab) {
        guard let draggedID, draggedID != tab.id,
              let moved = toolTabs.first(where: { $0.id == draggedID }),
              let index = toolTabs.firstIndex(where: { $0.id == tab.id })
        else { return }

        tabs.move(moved, to: index)
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
        CloseSessionAlert.shared.close(session, in: model)
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
            // The title alone. This value was read when the strip was drawn, and a running agent
            // has been writing its own columns into that row since, one of which is the id
            // `--resume` needs.
            try? await store.updateSessionPreferences(id: session.id, title: title)
            await model.reloadSessions()
        }
    }
}
