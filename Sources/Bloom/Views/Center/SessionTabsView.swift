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

    private var store: WorkspaceTabsStore { .shared }

    /// The strip, derived rather than stored.
    ///
    /// A tab owns a pane tree, so a thing living in a pane of some other tab is not also a tab of
    /// its own: it is reachable through the tab that has it, and an entry for it here would be a
    /// second way in. `TabSet.entries` is that rule, and everything below is a reading of this
    /// list rather than of the two stores under it.
    private var entries: [PaneContent] {
        store.entries(in: model)
    }

    private var sessionTabs: [Session] {
        entries.compactMap { entry in
            guard case .chat(let id) = entry else { return nil }
            return model.sessions.first { $0.id == id }
        }
    }

    private var toolTabs: [CenterTab] {
        let open = tabs.tabs(for: model.workspace.id)
        return entries.compactMap { entry in
            guard case .tool(let id) = entry else { return nil }
            return open.first { $0.id == id }
        }
    }

    /// Which tab the user is in. **One** answer, where `CenterPaneStore.isShowing` gave the strip
    /// as many marks as the column had panes: a tab owns the panes now, so being in a tab is a
    /// single fact about the workspace again.
    private var selectedTab: PaneContent? {
        store.selectedTab(in: model)
    }

    var body: some View {
        TabStrip(pane: Self.pane, selection: selectedID) {
            HStack(spacing: 0) {
                ForEach(Array(sessionTabs.enumerated()), id: \.element.id) { index, session in
                    if index > 0 {
                        TabStripSeparator(
                            isHidden: isSelected(sessionTabs[index - 1]) || isSelected(session)
                        )
                    }
                    sessionTab(session)
                        .id(session.id)
                }

                ForEach(Array(toolTabs.enumerated()), id: \.element.id) { index, tab in
                    if index > 0 || !sessionTabs.isEmpty {
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
        // The list, and nothing else. Reconciling used to be here too, right after this line, and
        // it was wrong by exactly one await: this body has no suspension point in it, so it ran
        // while `WorkspaceModel` was still on the `Store` actor and judged real tool tabs against
        // an empty session list. It is `CenterColumnView`'s task now, after `onAppear`.
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
        entries.map(\.id)
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
        switch selectedTab {
        case .chat(let id): sessionTabs.contains { $0.id == id } ? AnyHashable(id) : nil
        case .tool(let id): toolTabs.contains { $0.id == id } ? AnyHashable(id) : nil
        case nil: nil
        }
    }

    private func isSelected(_ session: Session) -> Bool {
        selectedTab == .chat(session.id)
    }

    private func isSelected(_ tab: CenterTab) -> Bool {
        selectedTab == .tool(tab.id)
    }

    /// Whether a tab is selected, named by id alone. The strip's two runs answer to two different
    /// cases of `PaneContent`, and `order` has already thrown that distinction away.
    private func isSelected(_ id: String) -> Bool {
        selectedTab?.id == id
    }

    /// Whether whatever sits immediately before this tool tab is the selected one, which is the
    /// last chat when the tool tabs start and the previous tool tab otherwise.
    private func isSelected(before tab: CenterTab, at index: Int) -> Bool {
        if index == 0 {
            return sessionTabs.last.map(isSelected) ?? false
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
            onSplitRight: splitAction(.chat(session.id), axis: .horizontal),
            onSplitDown: splitAction(.chat(session.id), axis: .vertical),
            namespace: selection
        )
        .draggable(session.id.rawValue)
        .dropDestination(for: String.self) { items, _ in
            Log.drag.notice("DROP on chat tab \(session.id.rawValue, privacy: .public) items \(items, privacy: .public)")
            move(items.first, onto: session)
        }
        .onDropSessionUpdated { drop in
            guard drop.phase == .entering else { return }
            Log.drag.notice("OVER chat tab \(session.id.rawValue, privacy: .public) at \(drop.location.debugDescription, privacy: .public) size \(drop.size.debugDescription, privacy: .public)")
        }
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
            onSelect: { store.select(.tool(tab.id), in: model) },
            onStartRename: { renamingID = tab.id },
            onCommitRename: {
                renamingID = nil
                tabs.rename(tab, to: $0)
            },
            onCancelRename: { renamingID = nil },
            onClose: { Task { await tabs.close(tab) } },
            onSplitRight: splitAction(.tool(tab.id), axis: .horizontal),
            onSplitDown: splitAction(.tool(tab.id), axis: .vertical),
            namespace: selection
        )
        .draggable(tab.id)
        .dropDestination(for: String.self) { items, _ in
            Log.drag.notice("DROP on tool tab \(tab.id, privacy: .public) items \(items, privacy: .public)")
            move(items.first, onto: tab)
        }
        .onDropSessionUpdated { drop in
            guard drop.phase == .entering else { return }
            Log.drag.notice("OVER tool tab \(tab.id, privacy: .public) at \(drop.location.debugDescription, privacy: .public) size \(drop.size.debugDescription, privacy: .public)")
        }
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

    /// Whether this tab can be opened beside the one the user is in. The pair of menu items is
    /// dropped when it cannot, rather than shown greyed, which is what `TabItemView` does with
    /// them everywhere else.
    ///
    /// False for a tab that carries a split arrangement of its own: folding it in would mean
    /// grafting its tree into another tree, which `SplitLayout` has no operation for. See
    /// `WorkspaceTabsStore.canAbsorb`.
    ///
    /// Also false for the review asked of itself, which has no second copy to make: a workspace
    /// has exactly one of it by design. See `PaneDuplicate`.
    private func splitAction(
        _ content: PaneContent, axis: SplitAxis
    ) -> (@MainActor () -> Void)? {
        guard canSplit(content) else { return nil }
        return { split(content, axis: axis) }
    }

    private func canSplit(_ content: PaneContent) -> Bool {
        guard let selectedTab else { return false }
        guard content != selectedTab else { return duplicable(content) }
        return store.canAbsorb(content)
    }

    private func duplicable(_ content: PaneContent) -> Bool {
        guard case .tool(let id) = content else { return true }
        return tabs.tabs(for: model.workspace.id).first { $0.id == id }?.kind != .review
    }

    /// Opens a tab beside the one the user asked from, rather than in place of it. The menu item
    /// beside the drag is there for anyone who would rather not drag, and for the keyboard.
    ///
    /// The tab it opens beside is the one the user is in, which is the whole arrangement rather
    /// than one pane of it, so the thing named here becomes a pane of that tab and drops out of
    /// the strip as an entry of its own. Asking this of the tab you are already in is asking for
    /// the same thing twice, which is `PaneDuplicate`'s question rather than this one's.
    private func split(_ content: PaneContent, axis: SplitAxis) {
        guard let tab = selectedTab else { return }
        let pane = store.focusedPane(of: tab)

        guard content != tab else {
            return PaneDuplicate.open(content, in: model) {
                store.split(tab: tab, pane: pane, axis: axis, showing: $0)
            }
        }
        store.split(tab: tab, pane: pane, axis: axis, showing: content)
    }

    /// All three go through `NewPane`, which is the same door the pane's split submenus use, so a
    /// tab made from the `+` and a tab made by splitting are the same tab.
    private func newChat() {
        NewPane.open(.chat, in: model) { store.select($0, in: model) }
    }

    private func newTerminal() {
        NewPane.open(.terminal, in: model) { store.select($0, in: model) }
    }

    /// The `+` opens a browser on the workspace's own dev server, where a split opens one on
    /// nothing. That is not drift: this item is the one that means "look at what this workspace is
    /// running", and it is the only route that has a port to hand.
    private func newBrowser() {
        Task {
            await preparePort()
            let address = model.port > 0 ? "http://localhost:\(model.port)" : ""
            NewPane.open(.browser, in: model, url: address) { store.select($0, in: model) }
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
    // in the sidebar. Anything else dropped on a tab, including text from another app, names
    // nothing in the run it was let go over, and `TabReorder` answers with nothing.
    //
    // Neither of these answers with a Bool. `dropDestination`'s action used to be asked whether it
    // had taken the drop; the macOS 26 one returns Void and is not asked, so a returned answer is
    // a value nobody reads and the compiler says so.
    //
    // Neither of them counts tabs any more. Both used to hand the store the target's OFFSET, and
    // the two lists that offset could be read in stopped being the same list the day the strip
    // became derived: `entries` is the stored run minus whatever a tab has absorbed. Stored `[T1, T2, T3]`
    // with `T2` living in a pane of another tab draws as `[T1, T3]`, so dragging `T1` onto `T3`
    // took offset 1 and produced `[T2, T1, T3]`, which reads back through the strip as `[T1, T3]`:
    // the order it started from. The tab sprang back under the pointer, nothing was logged, and
    // the gesture looked ignored. `TabReorder` states the answer in ids, over both lists at once,
    // and is in the core because that is a decision with cases worth testing.

    private func move(_ draggedID: String?, onto session: Session) {
        Log.drag.notice("MOVE chat dragged=\(draggedID ?? "nil", privacy: .public) onto=\(session.id.rawValue, privacy: .public) all=\(model.sessions.map(\.id.rawValue), privacy: .public) visible=\(sessionTabs.map(\.id.rawValue), privacy: .public)")
        guard let draggedID,
              let moved = model.sessions.first(where: { $0.id.rawValue == draggedID }),
              let order = TabReorder.reorder(
                  all: model.sessions.map(\.id),
                  visible: sessionTabs.map(\.id),
                  moving: moved.id,
                  onto: session.id
              ),
              // The place in the order `TabReorder` worked out, not a place counted off the strip.
              // `reorderSession` takes the moved session out before it puts it back, so an offset
              // into the finished order is exactly the offset it wants.
              let index = order.firstIndex(of: moved.id)
        else { return }

        Log.drag.notice("MOVE chat order=\(order.map(\.rawValue), privacy: .public) index=\(index, privacy: .public)")
        Task { await model.reorderSession(moved, to: index) }
    }

    private func move(_ draggedID: String?, onto tab: CenterTab) {
        Log.drag.notice("MOVE tool dragged=\(draggedID ?? "nil", privacy: .public) onto=\(tab.id, privacy: .public) all=\(tabs.tabs(for: model.workspace.id).map(\.id), privacy: .public) visible=\(toolTabs.map(\.id), privacy: .public)")
        guard let draggedID,
              let order = TabReorder.reorder(
                  all: tabs.tabs(for: model.workspace.id).map(\.id),
                  visible: toolTabs.map(\.id),
                  moving: draggedID,
                  onto: tab.id
              )
        else { return }

        Log.drag.notice("MOVE tool order=\(order, privacy: .public)")
        tabs.reorder(order, in: model.workspace.id)
    }

    // MARK: - Actions

    /// Picking a tab, which swaps the whole arrangement under it and writes no pane's content.
    ///
    /// The workspace's one active session moves with it, because the toolbar, the inspector and
    /// the pull request button all speak about one conversation. That is `WorkspaceTabsStore`'s
    /// job now rather than a second line here: a composite tab can be rooted on one chat and
    /// focused on another, and two callers deciding it separately is how they drift.
    private func select(_ session: Session) {
        store.select(.chat(session.id), in: model)
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
