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
    /// The namespace the selection fill matches across, so moving the selection slides one
    /// capsule between tabs instead of fading one out and another in. See `TabItemView`, which
    /// hangs its `matchedGeometryEffect` off this.
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
    /// second way in. `StripOrder.entries` is that rule together with whatever order the user has
    /// dragged the strip into, and everything below is a reading of this list rather than of the
    /// two stores under it.
    private var stored: [PaneContent] {
        store.entries(in: model)
    }

    /// The strip in the order it is DRAWING, which is the live order while a tab is being dragged
    /// along it and the stored one otherwise.
    ///
    /// **One list, not two runs.** The strip used to be conversations and then tools, because they
    /// are two kinds of thing kept in two stores; `TabSet` still says so and is still the fallback,
    /// but a user who has arranged their tabs is arranging one row and that is what this is. The
    /// owner has one conversation and one terminal, so under the old rule every drag he could make
    /// was one that could not be honoured.
    ///
    /// Reordering the `ForEach` rather than offsetting the tabs by hand, because the ids are stable
    /// and SwiftUI MOVES a view whose identity it already has rather than building a new one. That
    /// is safe here in a way it would not be a row lower: a tab in this strip is a label and a close
    /// button, and the live shell or web view it stands for lives in `CenterPaneView`, which this
    /// does not touch at all.
    private var entries: [PaneContent] {
        guard let drag, Set(drag.order) == Set(stored) else { return stored }
        return drag.order
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
                // One run over one list. A conversation and a terminal are two kinds of thing kept
                // in two stores, which is why they used to be drawn by two `ForEach`es in that
                // order, and it is still what the strip falls back to. It is not what the user is
                // arranging, though: they are arranging one row, and drawing it as two made the one
                // drag the owner could actually make into a drag that could not be honoured.
                ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
                    if index > 0 {
                        TabStripSeparator(isHidden: !isSeparated(at: index))
                    }

                    switch entry {
                    case .chat(let id):
                        if let session = session(id) {
                            sessionTab(session).id(id)
                        }
                    case .tool(let id):
                        if let tab = tool(id) {
                            toolTab(tab).id(id)
                        }
                    }
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

    /// The conversation or the tool tab one entry of the strip stands for, and nil for an entry
    /// whose content has gone between the strip being derived and this being asked.
    private func session(_ id: SessionID) -> Session? {
        model.sessions.first { $0.id == id }
    }

    private func tool(_ id: String) -> CenterTab? {
        tabs.tabs(for: model.workspace.id).first { $0.id == id }
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
        guard let selectedTab, entries.contains(selectedTab) else { return nil }
        return AnyHashable(selectedTab.id)
    }

    private func isSelected(_ session: Session) -> Bool {
        selectedTab == .chat(session.id)
    }

    private func isSelected(_ tab: CenterTab) -> Bool {
        selectedTab == .tool(tab.id)
    }

    /// Whether a tab is selected, named by id alone, for the callers that have thrown away which
    /// of the two kinds of thing it is. `order` is one such.
    private func isSelected(_ id: String) -> Bool {
        selectedTab?.id == id
    }

    /// Whether the rule between two tabs is drawn.
    ///
    /// Hidden against the selected tab on either side, whose own fill is its edge. One rule for the
    /// whole strip now that the strip is one list: the pair of cases this used to need, "the last
    /// conversation before the first tool" and "the tool before this one", were the seam between
    /// two runs and there is no seam any more.
    private func isSeparated(at index: Int) -> Bool {
        guard index > 0 else { return false }
        return !isSelected(entries[index - 1].id) && !isSelected(entries[index].id)
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
            canRename: tab.kind != .review && tab.kind != .notes,
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
        case .notes: "Close the notes"
        }
    }

    /// One control for all four kinds, because they differ in what they open and in nothing else.
    ///
    /// The shortcuts are drawn here and fired from the File menu. A `Menu` in a view becomes an
    /// `NSMenu` hanging off a button, and key equivalents are only offered to the menu bar and to
    /// the view hierarchy, neither of which that menu is in, so what is written here is a label.
    /// This used to be backed by an invisible `ZStack` of buttons that registered the same keys in
    /// the view hierarchy; the menu bar carries them now, and it has to be one or the other. A view
    /// hierarchy button and a menu item bound to the same key are not a tie: the button wins and
    /// the item never fires, measured.
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
            // Never disabled, unlike Changes: an empty note is exactly what somebody opening this
            // is about to fix, where an empty review has nothing to show.
            Button(CenterTab.notesTitle, systemImage: "note.text") { WorkspaceNotes.open(in: model) }
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
        let kind = tabs.tabs(for: model.workspace.id).first { $0.id == id }?.kind
        return kind != .review && kind != .notes
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
    /// what its dev server is answering on. Allocation lives on the model, where concurrent
    /// callers get one block. See `WorkspaceModel.ensurePort`.
    private func preparePort() async {
        await model.ensurePort()
    }

    // MARK: - Reordering
    //
    // The strip is one list and a tab goes anywhere in it. It was two runs, conversations and then
    // tools, and that rule is still what a workspace nobody has arranged reads as: they are two
    // kinds of thing kept in two stores with two lifetimes, a conversation being a SQLite row that
    // outlives the launch and a tool tab a line in user defaults that is better lost than migrated.
    // What that argument settles is where the ORDER can live, and it settles it well. What it does
    // not settle is what the user may drag, and treating it as though it did left the owner, whose
    // workspace is one conversation and one terminal, with no drag he could make that would be
    // honoured. See `StripOrder`, which holds the interleaving and what losing it costs.
    //
    // Every drag writes three times. The strip's own order is one key in defaults; the
    // conversations' order among themselves goes back to `sessions.sort_order` and the tools' to
    // their own list, so a workspace that loses the strip key keeps each kind in the order the user
    // put it in and loses only the mixing of the two.
    //
    // What is still refused here is refused for a reason rather than by leftover. Something from
    // another app names nothing the workspace has. A strip of one tab has no order to change. A
    // tab absorbed into a pane of another tab is not in the strip to be dragged. There is nothing
    // left that a drag inside the strip cannot ask for.
    //
    // The payload is the id rather than a `Transferable` of our own, matching the workspace rows in
    // the sidebar. It only has to name which tab is being carried: the ORDER comes from where the
    // pointer is, which is `TabDragOrder`, and by the time the drop arrives the strip has been
    // showing the answer for as long as the drag has lasted.
    //
    // The drop does not answer with a Bool. `dropDestination`'s action used to be asked whether it
    // had taken the drop; the macOS 26 one returns Void and is not asked.

    /// A drag of this tab has begun. The strip and where its tabs are now are frozen here, so the
    /// answer cannot chase its own tail once they start moving.
    private func begin(_ tab: PaneContent) {
        guard drag?.tab != tab else { return }
        let run = stored
        guard run.count > 1, run.contains(tab) else { return }
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
        let run = drag?.run ?? stored
        guard run.count > 1, run.contains(tab) else { return drag = nil }

        settle(drag?.order ?? TabDragOrder.live(
            run, moving: tab, centres: drag?.centres ?? centres, to: pointer
        ))
    }

    /// The other end of the same gesture. A tab let go over a PANE is taken by the pane and the
    /// strip's own drop never runs, so the preview would sit there for good; a drag thrown away
    /// outside the window has to spring back rather than be written.
    private func finish(taken: Bool) {
        guard let current = drag else { return }
        guard taken else { return drag = nil }
        settle(current.order)
    }

    /// Writes the order the strip has been showing, and clears the preview. Whichever end of the
    /// drag gets here first does the work, and the other finds nothing pending.
    ///
    /// Three writes, and the two after the first are what make a lost defaults file cost only the
    /// interleaving. The strip's own order is one key in user defaults; the conversations' order
    /// among themselves goes back to `sessions.sort_order` in SQLite and the tools' among
    /// themselves to their own list, so a workspace that loses the strip key comes back with each
    /// kind in the order the user put it in and only the mixing of the two undone. See
    /// `StripOrder`, where that cost is written out.
    private func settle(_ order: [PaneContent]) {
        drag = nil
        store.reorder(order, in: model)
        reorderSessions(within: order)
        reorderTools(within: order)
    }

    /// What a dragged id names. The payload is a bare id, because that is what the strip has always
    /// sent, so which of the two kinds it is is recovered by looking it up.
    private func content(named id: String) -> PaneContent? {
        if model.sessions.contains(where: { $0.id.rawValue == id }) { return .chat(SessionID(id)) }
        if tabs.tabs(for: model.workspace.id).contains(where: { $0.id == id }) { return .tool(id) }
        return nil
    }

    private func reorderSessions(within strip: [PaneContent]) {
        let drawn = strip.compactMap { entry -> SessionID? in
            guard case .chat(let id) = entry else { return nil }
            return id
        }
        guard let order = TabReorder.apply(drawn, to: model.sessions.map(\.id)) else { return }
        model.reorderSessions(to: order)
    }

    private func reorderTools(within strip: [PaneContent]) {
        let drawn = strip.compactMap { entry -> String? in
            guard case .tool(let id) = entry else { return nil }
            return id
        }
        let stored = tabs.tabs(for: model.workspace.id).map(\.id)
        guard let order = TabReorder.apply(drawn, to: stored) else { return }
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
