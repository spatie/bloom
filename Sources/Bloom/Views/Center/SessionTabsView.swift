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
    /// A tab being dragged along the strip, and the order the strip is showing because of it.
    ///
    /// The tabs move out from under the pointer while the drag is happening, so letting go changes
    /// nothing anyone can see and the write behind it is never something they wait for. Before
    /// this, a drop was the first moment anything moved: whatever the system spent tearing the
    /// drag down was a wait, with the gesture apparently ignored until it ended, which is what the
    /// owner reported as "swapping takes a second".
    @State private var drag: StripDrag?
    /// Where each tab is centred along the strip. Written continuously, read only as a snapshot at
    /// the start of a drag.
    @State private var centres: [PaneContent: Double] = [:]
    /// Which workspace's strip has finished arriving, so the first draw of a workspace is not
    /// animated. Switching workspace replaces every id in the strip at once, and without this the
    /// selection would fly in from wherever the previous workspace happened to have it.
    @Namespace private var selection

    /// One tab being dragged, and everything needed to say where it has got to.
    private struct StripDrag: Equatable {
        /// The tab under the pointer.
        var tab: PaneContent
        /// Its run, in the order it was stored when the drag began.
        var run: [PaneContent]
        /// Where each tab of that run was centred when the drag began. A snapshot on purpose:
        /// measuring them again while they are moving would feed the answer back into itself and
        /// the run would judder.
        var centres: [PaneContent: Double]
        /// What the strip is showing now.
        var order: [PaneContent]
    }

    /// The space the tabs are measured in and the pointer is reported in. It is the row of tabs
    /// itself, so it scrolls with them and the two sets of numbers cannot drift apart.
    private static let stripSpace = "bloom.tabStrip"

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

    /// The conversations run, in the order the strip is DRAWING it, which is the live order while
    /// a tab is being dragged along it and the stored order otherwise.
    private var sessionTabs: [Session] {
        arranged(storedSessionTabs) { .chat($0.id) }
    }

    private var storedSessionTabs: [Session] {
        entries.compactMap { entry in
            guard case .chat(let id) = entry else { return nil }
            return model.sessions.first { $0.id == id }
        }
    }

    /// The tools run, in the order the strip is DRAWING it. See `sessionTabs`.
    private var toolTabs: [CenterTab] {
        arranged(storedToolTabs) { .tool($0.id) }
    }

    private var storedToolTabs: [CenterTab] {
        let open = tabs.tabs(for: model.workspace.id)
        return entries.compactMap { entry in
            guard case .tool(let id) = entry else { return nil }
            return open.first { $0.id == id }
        }
    }

    /// A run put into the order a drag is currently showing, or left alone when the drag is in the
    /// other run or when there is no drag.
    ///
    /// Reordering the `ForEach` rather than offsetting the tabs by hand, because the ids are stable
    /// and SwiftUI MOVES a view whose identity it already has rather than building a new one. That
    /// is safe here in a way it would not be a row lower: a tab in this strip is a label and a close
    /// button, and the live shell or web view it stands for lives in `CenterPaneView`, which this
    /// does not touch at all.
    ///
    /// Only the run the drag belongs to, matched by its whole set of ids rather than by a flag, so
    /// the other run cannot be rearranged by a drag that has nothing to do with it.
    private func arranged<Item>(_ run: [Item], by name: (Item) -> PaneContent) -> [Item] {
        guard let drag else { return run }
        let byContent = Dictionary(run.map { (name($0), $0) }, uniquingKeysWith: { first, _ in first })
        guard byContent.count == run.count, Set(byContent.keys) == Set(drag.order) else { return run }
        return drag.order.compactMap { byContent[$0] }
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
            .coordinateSpace(.named(Self.stripSpace))
            // Where the pointer is, continuously, for as long as a drag is over the strip. This is
            // what moves the tabs out of the way: `onDropSessionUpdated` carries a live location
            // where `isTargeted` only says in or out.
            .onDropSessionUpdated { session in
                switch session.phase {
                case .entering, .active: follow(session.location.x)
                default: return
                }
            }
            // One destination for the whole row rather than one per tab. By the time a drag is let
            // go the strip has been showing the answer for as long as the user has been dragging,
            // so which tab it happens to land on decides nothing.
            .dropDestination(for: String.self) { items, session in
                commit(items.first, at: session.location.x)
            }
            // Only when a drag moves the tabs. A reload that came from anywhere else, a session
            // arriving or a tab being renamed, must not make the strip slide about.
            .animation(.snappy(duration: 0.18), value: drag?.order)
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
            // Always. The workspace's last conversation IS closable, and hiding the cross was the
            // only thing pretending otherwise: "Close Session" in the File menu holds Cmd+W and has
            // never had such a guard. What closing costs is asked about instead of drawn around.
            // See `SessionClosure`.
            canClose: true,
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
        .modifier(StripDragTracking(
            content: .chat(session.id),
            space: Self.stripSpace,
            onMeasure: { centres[.chat(session.id)] = $0 },
            onBegin: { begin(.chat(session.id)) },
            onEnd: { finish(taken: $0) }
        ))
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
        .modifier(StripDragTracking(
            content: .tool(tab.id),
            space: Self.stripSpace,
            onMeasure: { centres[.tool(tab.id)] = $0 },
            onBegin: { begin(.tool(tab.id)) },
            onEnd: { finish(taken: $0) }
        ))
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

    /// A drag of this tab has begun. The run and where its tabs are now are frozen here, so the
    /// answer cannot chase its own tail once they start moving.
    private func begin(_ tab: PaneContent) {
        guard drag?.tab != tab else { return }
        let run = run(containing: tab)
        guard run.count > 1 else { return }
        drag = StripDrag(tab: tab, run: run, centres: centres, order: run)
    }

    /// The pointer has moved. Nothing else about the strip is touched: this is the only thing that
    /// writes the live order, and it writes it only when it has actually changed, because assigning
    /// an equal value is still a mutation as far as Observation is concerned.
    private func follow(_ pointer: Double) {
        guard var current = drag else { return }
        let order = TabDragOrder.live(
            current.run, moving: current.tab, centres: current.centres, to: pointer
        )
        guard order != current.order else { return }
        current.order = order
        drag = current
    }

    /// The drag has been let go over the strip. What is written is the order the strip has been
    /// SHOWING, never a rule about which tab it happened to land on: a live preview that commits
    /// something else is the one thing worse than no preview at all.
    ///
    /// It falls back to working the order out here, from the payload and where the pointer was,
    /// when there is no live drag to read. That is not a leftover. `onDragSessionUpdated` is what
    /// says a drag has begun, and if it were ever not to fire, reordering would stop working
    /// altogether rather than merely stop animating. The fallback is the same computation done once
    /// instead of continuously.
    private func commit(_ droppedID: String?, at pointer: Double) {
        guard let tab = drag?.tab ?? droppedID.flatMap(content(named:)) else { return }
        let run = drag?.run ?? run(containing: tab)
        guard run.count > 1 else { return drag = nil }

        settle(
            drag?.order ?? TabDragOrder.live(
                run, moving: tab, centres: drag?.centres ?? centres, to: pointer
            ),
            of: tab
        )
    }

    /// The other end of the same gesture. A tab let go over a PANE is taken by the pane and the
    /// strip's own drop never runs, so the preview would sit there for good; a drag thrown away
    /// outside the window has to spring back rather than be written.
    private func finish(taken: Bool) {
        guard let current = drag else { return }
        guard taken else { return drag = nil }
        settle(current.order, of: current.tab)
    }

    /// Writes a run's new order and clears the preview. Whichever end of the drag gets here first
    /// does the work, and the other finds nothing pending.
    private func settle(_ order: [PaneContent], of tab: PaneContent) {
        drag = nil
        switch tab {
        case .chat: reorderSessions(to: order)
        case .tool: reorderTools(to: order)
        }
    }

    /// Which run a tab belongs to, and empty for something that is in neither, which is anything
    /// dropped here from outside the app.
    private func run(containing tab: PaneContent) -> [PaneContent] {
        let chats = storedSessionTabs.map { PaneContent.chat($0.id) }
        if chats.contains(tab) { return chats }
        let tools = storedToolTabs.map { PaneContent.tool($0.id) }
        return tools.contains(tab) ? tools : []
    }

    /// What a dragged id names. The payload is a bare id, because that is what the strip has always
    /// sent, so which of the two runs it belongs to is recovered by looking it up.
    private func content(named id: String) -> PaneContent? {
        if model.sessions.contains(where: { $0.id.rawValue == id }) { return .chat(SessionID(id)) }
        if tabs.tabs(for: model.workspace.id).contains(where: { $0.id == id }) { return .tool(id) }
        return nil
    }

    private func reorderSessions(to visible: [PaneContent]) {
        let drawn = visible.compactMap { content -> SessionID? in
            guard case .chat(let id) = content else { return nil }
            return id
        }
        guard drawn.count == visible.count,
              let order = TabReorder.apply(drawn, to: model.sessions.map(\.id)) else { return }
        model.reorderSessions(to: order)
    }

    private func reorderTools(to visible: [PaneContent]) {
        let drawn = visible.compactMap { content -> String? in
            guard case .tool(let id) = content else { return nil }
            return id
        }
        let stored = tabs.tabs(for: model.workspace.id).map(\.id)
        guard drawn.count == visible.count,
              let order = TabReorder.apply(drawn, to: stored) else { return }
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
