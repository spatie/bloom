import SwiftUI
import BloomCore

/// The strip of tabs inside one workspace: parallel conversations, shells and pages.
///
/// Sessions share a worktree but not a context window, which is the whole point: a question about
/// the code should not cost the turn that is halfway through writing it. A terminal and a browser
/// share the worktree too, and share the strip for the same reason, so the thing you look at next
/// is always one click along the same row.
///
/// Whether the strip is drawn at all is `CenterColumnView`'s to decide, by `TabStripVisibility`:
/// a workspace with one tab has no strip, however that tab is split, the way a Safari window with
/// one tab has no tab bar. The `+` that used to end this row is `NewTabMenu`, in the title bar,
/// which is what lets the row go.
struct SessionTabsView<Model: WorkspacePaneModel>: View {
    @Bindable var model: Model
    /// The tab whose name field is open. Owned by the column rather than by this view, because
    /// Rename Tab has to be able to open a field on a strip that is not drawn yet: the column
    /// hears the request, sets this, and the strip appears with the field already open.
    @Binding var renamingID: String?

    /// The tab being carried, if any. Owned by the column, because the column draws where a tab
    /// taken out of the strip would land. See `TabCarry`.
    var carry: TabCarry
    /// Which tabs sweep. The column's to resolve, because the column's top edge carries the other
    /// half of the same answer when this strip is not drawn.
    var busy: BusySignalPlacement<PaneContent>
    /// Which part of which pane a tab carried to a point in `CenterColumnView.space` would land in,
    /// or nil for anywhere that would not take it. The column's to answer, because the panes are
    /// the column's.
    var landing: (PaneContent, CGPoint) -> PaneLanding?
    /// Lets a carried tab go over that landing.
    var drop: (PaneContent, PaneLanding) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where each tab sits along the strip. Written continuously, read only as a snapshot at the
    /// start of a drag.
    ///
    /// In a box rather than in `@State`, for the reason `GeometryBox` sets out and because the
    /// sentence above is the whole argument: nothing draws these numbers. Every tab's probe wrote
    /// one on every frame of a window resize, and each of those writes rebuilt this strip and
    /// every tab in it.
    @State private var spans = GeometryBox([PaneContent: TabStripDrag.Span]())
    /// The strip's own vertical extent in `CenterColumnView.space`, which is how a carried tab
    /// knows it has left the strip. A box for the same reason as `spans`.
    @State private var band = GeometryBox(0.0...0.0)
    /// The namespace the selection fill matches across, so moving the selection slides one
    /// capsule between tabs instead of fading one out and another in. See `TabItemView`, which
    /// hangs its `matchedGeometryEffect` off this.
    @Namespace private var selection
    /// Which tab the pointer is over, read by the dividers alone. See `TabStripHover`.
    @State private var hover = TabStripHover()

    /// The space the tabs are measured in and the pointer is reported in. It is the row of tabs
    /// itself, so it scrolls with them and the two sets of numbers cannot drift apart.
    private static var stripSpace: String { "bloom.tabStrip" }

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

    var body: some View {
        // Derived once, at the top, and threaded down to everything that needs it.
        //
        // `entries` is not a stored list: it maps the sessions, reads the tool tab list, works out
        // what the tabs have absorbed and lays the user's own order over the result. It used to be
        // asked for again by the separator between every pair of tabs (twice each), by the scroll
        // target, by every split menu, and once more inside the store on the way to the
        // selection. That is about six full
        // derivations per tab per pass for a list that cannot change while the pass is running.
        //
        // This is `SidebarRepoGroup`'s bug and `SidebarRepoGroup`'s fix: derive it once, pass it
        // as a parameter, and let the helpers say what they need rather than reach for it.
        let entries = stored
        // Nothing about the drag is read here. Where the carried tab has got to is read by each
        // tab's own `StripDragTracking` and by each `StripDivider`, so the pointer moving does not
        // rebuild this body. See `TabCarry`.
        //
        // **One** answer, where `CenterPaneStore.isShowing` gave the strip as many marks as the
        // column had panes: a tab owns the panes now, so being in a tab is a single fact about the
        // workspace again.
        let selected = store.selectedTab(in: model, entries: entries)
        // Which tab the strip scrolls into view, as a plain id rather than as `PaneContent`.
        //
        // Nil when the focused pane is showing something the strip does not have a tab for, which
        // is the moment after a tab is closed: aiming a scroll at an id that is no longer laid out
        // does nothing, and this says so rather than relying on that.
        let selectedID = selected.flatMap { entries.contains($0) ? AnyHashable($0.id) : nil }
        return TabStrip(tabCount: entries.count, pane: Self.pane, selection: selectedID) {
            EmptyView()
        } tabs: {
            HStack(spacing: 0) {
                // Stable identities let conversations and tools move through the same row.
                ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
                    if index > 0 {
                        StripDivider(
                            slot: index - 1, entries: entries, selected: selected,
                            carry: carry, hover: hover, busy: busy
                        )
                    }

                    switch entry {
                    case .chat(let id):
                        if let session = session(id) {
                            sessionTab(session, selected: selected, entries: entries)
                                .id(id)
                        }
                    case .tool(let id):
                        if let tab = tool(id) {
                            toolTab(tab, selected: selected, entries: entries)
                                .id(id)
                        }
                    }
                }
            }
            .coordinateSpace(.named(Self.stripSpace))
        } append: {
        } trailing: {}
        .onGeometryChange(for: ClosedRange<Double>.self) { proxy in
            let frame = proxy.frame(in: .named(CenterColumnView<WorkspaceModel>.space))
            return Double(frame.minY)...Double(frame.maxY)
        } action: {
            band.value = $0
        }
        // A strip taken away mid drag, which a workspace switch does, must not leave a tab in the
        // air or an Escape monitor installed.
        .onDisappear { carry.end() }
        // The list, and nothing else. Reconciling used to be here too, and it was wrong by exactly
        // one await: this body has no suspension point in it, so it ran while `WorkspaceModel` was
        // still on the `Store` actor and judged real tool tabs against an empty session list. It is
        // `CenterColumnView`'s task now, after `onAppear`. So are hearing Rename Tab and loading
        // the stored tabs, because this view is not in the hierarchy while the strip is hidden and
        // neither may wait for it to be.
    }

    /// The centre column opens onto the reading ground, which settles both what a selected tab is
    /// filled with and how far the track under it is sunk. See `TabPane`, which carries the
    /// measurements that used to live here.
    private static var pane: TabPane { TabPane.content }

    /// The conversation or the tool tab one entry of the strip stands for, and nil for an entry
    /// whose content has gone between the strip being derived and this being asked.
    private func session(_ id: SessionID) -> Session? {
        model.sessions.first { $0.id == id }
    }

    private func tool(_ id: String) -> CenterTab? {
        tabs.tabs(for: model.workspace.id).first { $0.id == id }
    }

    // MARK: - Tabs

    private func sessionTab(
        _ session: Session, selected: PaneContent?, entries: [PaneContent]
    ) -> some View {
        let content = PaneContent.chat(session.id)
        return SessionTabView(
            session: session,
            agentGlyph: sessionGlyph(for: session),
            isActive: selected == .chat(session.id),
            isRunning: busy.showsInTab(content),
            isRenaming: renamingID == session.id.rawValue,
            // Always. The workspace's last conversation IS closable, and hiding the cross was the
            // only thing pretending otherwise: "Close Session" in the File menu holds Cmd+W and has
            // never had such a guard. What closing costs is asked about instead of drawn around.
            // See `SessionClosure`.
            canClose: true,
            onSelect: {
                guard !carry.swallowsSelect else { return }
                select(session)
            },
            onStartRename: { renamingID = session.id.rawValue },
            onCommitRename: { commitRename(session, to: $0) },
            onCancelRename: { renamingID = nil },
            onClose: { close(session) },
            onSplitRight: splitAction(.chat(session.id), axis: .horizontal, selected: selected),
            onSplitDown: splitAction(.chat(session.id), axis: .vertical, selected: selected),
            onMoveLeft: moveAction(content, by: -1, in: entries),
            onMoveRight: moveAction(content, by: 1, in: entries),
            onHover: { hover.set(content, isHovered: $0) },
            namespace: selection
        )
        .modifier(tracking(
            content,
            isEnabled: renamingID != session.id.rawValue,
            title: session.title.isEmpty ? PaneNaming.untitledChat : session.title,
            symbol: PaneGlyph.chatTab(agentMark: sessionGlyph(for: session))
        ))
    }

    private func sessionGlyph(for session: Session) -> String? {
        if let turn = TerminalSessionStore.shared.agentTurns[session.id], turn.isAwaitingPermission {
            return "questionmark.circle"
        }
        if CenterTabStore.shared.terminal(for: session.id, in: model.workspace.id) != nil {
            return PaneGlyph.agentMark(for: session.agentKind)
        }
        return PaneGlyph.agentMark(for: session.agentKind, among: model.sessions.map(\.agentKind))
    }

    private func toolTab(
        _ tab: CenterTab, selected: PaneContent?, entries: [PaneContent]
    ) -> some View {
        let content = PaneContent.tool(tab.id)
        return TabItemView(
            title: tabs.displayTitle(of: tab, in: model),
            icon: icon(for: tab),
            isActive: selected == .tool(tab.id),
            // A run script's tab sweeps the way a working conversation's does while its command
            // is going. An ordinary terminal never does: nothing polls it, and a shell somebody ran
            // `ls` in is not a thing anybody is waiting on. See `WorkspaceTabsStore.busySignal`.
            isRunning: busy.showsInTab(content),
            surface: Self.pane.surface,
            isRenaming: renamingID == tab.id,
            // What is on the tab, not what the tab is filed under. A browser showing "Spatie"
            // whose editor opened on "Browser" reads as the rename having gone to the wrong tab,
            // and the first thing anyone does is select all and retype the name they could
            // already see.
            editableTitle: tabs.displayTitle(of: tab, in: model),
            canClose: true,
            canRename: TabRenaming.canRename(.tool(tab.id), tabKind: tab.kind),
            closeTitle: closeTitle(for: tab),
            onSelect: {
                guard !carry.swallowsSelect else { return }
                store.select(.tool(tab.id), in: model)
            },
            onStartRename: { renamingID = tab.id },
            onCommitRename: {
                renamingID = nil
                tabs.rename(tab, to: $0)
            },
            onCancelRename: { renamingID = nil },
            onClose: { Task { await tabs.close(tab, in: model) } },
            onSplitRight: splitAction(.tool(tab.id), axis: .horizontal, selected: selected),
            onSplitDown: splitAction(.tool(tab.id), axis: .vertical, selected: selected),
            onMoveLeft: moveAction(content, by: -1, in: entries),
            onMoveRight: moveAction(content, by: 1, in: entries),
            onHover: { hover.set(content, isHovered: $0) },
            namespace: selection
        )
        .modifier(tracking(
            content,
            isEnabled: renamingID != tab.id,
            title: tabs.displayTitle(of: tab, in: model),
            symbol: tab.icon
        ))
    }

    /// What a tool tab wears. Three of the four kinds have a glyph of Bloom's own; a browser wears
    /// the page's own favicon, or the globe until one arrives and for ever if none does.
    ///
    /// A dictionary lookup behind one address parse, which is what it costs to ask this from a
    /// body that redraws on a window resize. See `BrowserFaviconStore`.
    private func icon(for tab: CenterTab) -> TabItemIcon {
        if tab.kind == .terminal,
           let agent = TerminalSessionStore.shared.detectedAgent(inTab: tab.id) {
            return .symbol(PaneGlyph.agentMark(for: agent))
        }
        if tab.kind == .terminal, let script = runScript(of: tab) {
            return .symbol(RunScriptGlyph.symbol(for: script.icon))
        }
        guard tab.kind == .browser else { return .symbol(tab.icon) }
        return .page(BrowserFaviconStore.shared.icon(for: tab.url))
    }

    /// The run script a terminal tab was opened for, as the settings file states it now.
    private func runScript(of tab: CenterTab) -> RunScript? {
        guard let id = tab.runScriptID else { return nil }
        return model.localWorkspaceModel?.settings.runScripts.first { $0.id == id }
    }

    private func closeTitle(for tab: CenterTab) -> String {
        switch tab.kind {
        case .terminal: "Close terminal"
        case .browser: "Close browser"
        case .review: "Close the review"
        case .notes: "Close the notes"
        }
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
        _ content: PaneContent, axis: SplitAxis, selected: PaneContent?
    ) -> (@MainActor () -> Void)? {
        guard canSplit(content, selected: selected) else { return nil }
        return { split(content, axis: axis) }
    }

    private func canSplit(_ content: PaneContent, selected: PaneContent?) -> Bool {
        guard let selected else { return false }
        guard content != selected else { return duplicable(content) }
        return store.canAbsorb(content)
    }

    /// Whether asking for this tab beside itself would produce anything. The rule was written out
    /// here as a third copy of `kind != .review && kind != .notes`; it is `PaneSplit`'s, through
    /// the same door the split itself goes through, so the menu item and the split cannot come to
    /// different answers about one tab.
    private func duplicable(_ content: PaneContent) -> Bool {
        PaneDuplicate.canOpen(content, in: model)
    }

    /// Opens a tab beside the one the user asked from, rather than in place of it. The menu item
    /// beside the drag is there for anyone who would rather not drag, and for the keyboard.
    ///
    /// The tab it opens beside is the one the user is in, which is the whole arrangement rather
    /// than one pane of it, so the thing named here becomes a pane of that tab and drops out of
    /// the strip as an entry of its own. Asking this of the tab you are already in is asking for
    /// the same thing twice, which is `PaneDuplicate`'s question rather than this one's.
    private func split(_ content: PaneContent, axis: SplitAxis) {
        guard let tab = store.selectedTab(in: model) else { return }
        let pane = store.focusedPane(of: tab)

        guard content != tab else {
            return PaneDuplicate.open(content, in: model) {
                store.split(tab: tab, pane: pane, axis: axis, showing: $0)
            }
        }
        store.split(tab: tab, pane: pane, axis: axis, showing: content)
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
    // A tab is carried by a `DragGesture` rather than handed to AppKit as a system drag, so the tab
    // itself follows the pointer and its neighbours slide out of its way. See `TabCarry` for why,
    // and `TabStripDrag` for the arithmetic.
    //
    // **The order is written once, when the tab is let go, and never while it is moving.** Every
    // write is three writes, one of them a SQLite row per conversation, and the strip does not
    // need the store to tell it where the tabs are mid drag: each tab's offset is drawn from the
    // snapshot. Writing live would mean a write per slot crossed, and every one of them re-derives
    // the strip under a gesture whose geometry was measured against the order before it.

    private var motion: Animation? {
        reduceMotion ? nil : Motion.pane
    }

    private func tracking(
        _ content: PaneContent, isEnabled: Bool, title: String, symbol: String
    ) -> StripDragTracking {
        StripDragTracking(
            content: content,
            carry: carry,
            stripSpace: Self.stripSpace,
            columnSpace: CenterColumnView<WorkspaceModel>.space,
            isEnabled: isEnabled,
            onMeasure: { spans.value[content] = $0 },
            onChanged: { carried(content, $0, title: title, symbol: symbol) },
            onEnded: { letGo(content) }
        )
    }

    /// The pointer has moved with the button down on `content`.
    private func carried(_ content: PaneContent, _ value: DragGesture.Value, title: String, symbol: String) {
        guard !carry.isCancelled else { return }
        if carry.lift == nil, !pickUp(content, title: title, symbol: symbol) { return }
        guard let lift = carry.lift, lift.content == content else { return }
        // A tab opened or closed while this one was in the air, by an agent or a run script, means
        // the snapshot describes a strip that is no longer there. Putting the tab back is honest;
        // carrying on would commit an order computed against the wrong list.
        guard stored == lift.run else { return carry.cancel(animation: motion) }

        let isInStrip = TabStripDrag.isInStrip(Double(value.location.y), band: band.value)
        carry.move(
            travel: Double(value.translation.width),
            pointer: value.location,
            isInStrip: isInStrip,
            landing: isInStrip ? nil : landing(content, value.location),
            animation: motion
        )
    }

    /// A drag of this tab has begun. The strip and where its tabs are now are frozen here, so the
    /// answer cannot chase its own tail once they start moving. False when there is nothing to
    /// carry: a strip of one tab, or one whose tabs have not all been measured yet.
    private func pickUp(_ content: PaneContent, title: String, symbol: String) -> Bool {
        let run = stored
        guard let index = run.firstIndex(of: content) else { return false }
        let measured = run.compactMap { spans.value[$0] }
        guard measured.count == run.count,
              let geometry = TabStripDrag(spans: measured, dragged: index) else { return false }
        carry.begin(
            TabCarry.Lift(content: content, run: run, geometry: geometry, title: title, symbol: symbol),
            cancelAnimation: motion
        )
        return true
    }

    /// The button has come up.
    ///
    /// Inside the strip, the order it has been showing is written, in the same transaction that
    /// takes the offsets away. That is what makes the tab settle rather than jump: every neighbour
    /// is already drawn at its new slot, so moving it there in the layout and removing its offset
    /// cancel out and it does not move, while the carried tab slides the rest of the way from the
    /// pointer into its slot. Out over a pane, it is the column's to place. Anywhere else it goes
    /// back where it was.
    private func letGo(_ content: PaneContent) {
        defer { carry.gestureEnded() }
        guard let lift = carry.lift, lift.content == content else { return }

        if carry.isInStrip, let target = carry.target {
            let order = lift.geometry.order(lift.run, target: target)
            withAnimation(motion) {
                carry.end()
                if order != lift.run { settle(order) }
            }
        } else if let landing = carry.landing {
            carry.end()
            drop(content, landing)
        } else {
            withAnimation(motion) { carry.end() }
        }
    }

    /// Moving a tab one place along without a pointer, for the accessibility actions. Nil at the
    /// end it cannot move past, so the action is not offered there.
    private func moveAction(
        _ content: PaneContent, by step: Int, in entries: [PaneContent]
    ) -> (@MainActor () -> Void)? {
        guard let index = entries.firstIndex(of: content),
              let order = TabStripDrag.moved(entries, from: index, by: step) else { return nil }
        return { withAnimation(motion) { settle(order) } }
    }

    /// Writes the order the strip has been showing.
    ///
    /// Three writes, and the two after the first are what make a lost defaults file cost only the
    /// interleaving. The strip's own order is one key in user defaults; the conversations' order
    /// among themselves goes back to `sessions.sort_order` in SQLite and the tools' among
    /// themselves to their own list, so a workspace that loses the strip key comes back with each
    /// kind in the order the user put it in and only the mixing of the two undone. See
    /// `StripOrder`, where that cost is written out.
    private func settle(_ order: [PaneContent]) {
        store.reorder(order, in: model)
        reorderSessions(within: order)
        reorderTools(within: order)
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
        guard !title.isEmpty, title != session.title else { return }
        Task { await model.renameSession(session, title: title) }
    }
}
