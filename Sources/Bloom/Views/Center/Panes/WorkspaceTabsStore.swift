import SwiftUI
import Observation
import BloomCore

/// The panes inside each of a workspace's tabs, and which tab the user is in.
///
/// **A tab owns a pane tree.** That is the whole of this type, and it is the other way round from
/// `CenterPaneStore`, which it replaces. There a workspace owned one tree, panes were the outer
/// container, and the strip was a content switcher for whichever pane had the keyboard: clicking a
/// tab called `show(_:in:)` and rewrote that pane, so standing in a split and picking a tab
/// changed the half you were standing in rather than the arrangement. Here picking a tab swaps the
/// whole tree, and **`select` writes no pane's content at all.**
///
/// A singleton for the same reason `CenterTabStore` and `TerminalSplitStore` are: the arrangement
/// has to outlive the view drawing it, so switching workspace and back cannot lose a split or
/// reload a page.
///
/// It holds the shape and the pointers, never the content. A pane names a session id or a tool tab
/// id, and the transcript, the shell and the web view all still hang off the stores that own them,
/// so closing a pane can never take a running agent with it by accident.
///
/// **The strip is derived rather than stored.** `TabSet.entries` builds it from the workspace's
/// sessions and its tool tabs, minus anything already living as a pane of another tab, so nothing
/// has to remember to add or remove an entry when a pane opens or closes, and there is one
/// selection instead of the two marks `isShowing` put up at once.
///
/// The unsplit case is still the default and still costs nothing: one pane carrying the id of the
/// content at the tab's root, no stored layout, no stored pointer. A tab nobody has split behaves
/// exactly as it did before panes existed.
///
/// What it decides itself is only user defaults and observation. Whether a tab survives a pane
/// going, and what it is called when the content it was named after has left, are
/// `BloomCore.TabSurgery`, because a store in `Sources/Bloom` is a store the suite cannot reach.
@MainActor
@Observable
final class WorkspaceTabsStore {
    static let shared = WorkspaceTabsStore()

    /// One split tab: what it is filed under, its tree, and what each of its panes points at.
    ///
    /// Nested rather than the two flat maps `CenterPaneStore` kept, because a tab is what gets
    /// written, read, re-filed and dropped as a unit, and a flat pointer map means remembering to
    /// walk a dissolved arrangement and delete its keys by hand.
    ///
    /// `root` is carried rather than derived from the key: the key on disk holds the id with the
    /// kind thrown away, and the kind is recovered once, at load, from the pointer the record
    /// spells out for the root's own pane.
    private struct Arrangement {
        var root: PaneContent
        var layout: SplitLayout
        /// Pane id to what that pane points at. Every pane of a split tab has an entry.
        var contents: [String: PaneContent]

        init(root: PaneContent, layout: SplitLayout, contents: [String: PaneContent]) {
            self.root = root
            self.layout = layout
            self.contents = contents
        }

        init?(root: PaneContent, stored: StoredPaneArrangement) {
            guard let layout = SplitLayout(encoded: stored.layout) else { return nil }
            self.init(root: root, layout: layout, contents: stored.contents)
        }

        /// Pruned to the panes that actually exist, which is what gets written down.
        var stored: StoredPaneArrangement? {
            guard let encoded = layout.encoded else { return nil }
            let panes = Set(layout.panes)
            return StoredPaneArrangement(
                layout: encoded, contents: contents.filter { panes.contains($0.key) }
            )
        }

        /// Whether this tab can take a content in a pane without breaking the one view rule.
        ///
        /// A terminal and a browser are each one live `NSView`, and mounting one in two places has
        /// never worked: the second pane takes the view away from the first, which then draws
        /// nothing. `TabMigration.invert` refuses to carry that shape across a migration for the
        /// same reason, and a chat is exempt in both places because a transcript renders twice
        /// happily.
        func canHold(_ content: PaneContent) -> Bool {
            guard case .tool = content else { return true }
            return !layout.panes.contains { contents[$0] == content }
        }
    }

    /// Split tabs only, keyed by the id of the content at the root. An unsplit tab is the absence
    /// of an entry, which is what makes it free.
    private var arrangements: [String: Arrangement] = [:]

    /// Which tab each workspace is in. In memory only, and deliberately so: an unsplit selection
    /// was never persisted before either, because `CenterPaneStore.persist` removed the key
    /// whenever the column was down to one pane. A launch has always opened on the active
    /// conversation and it still does.
    private var selected: [WorkspaceID: PaneContent] = [:]

    /// The order each workspace's strip has been dragged into, over the two runs it would otherwise
    /// read as. Absent for a workspace nobody has arranged, which reads exactly as it always did.
    /// See `BloomCore.StripOrder`, which carries the rule and what a lost defaults file costs.
    private var stripOrders: [WorkspaceID: [PaneContent]] = [:]

    /// Read in one pass at launch rather than lazily per workspace. A getter may not mutate, and
    /// loading from a task would leave the first frame showing a single pane, which is long enough
    /// to fork a shell for a pane the restored layout does not have.
    ///
    /// The migration runs at the top of it for the same reason. Phase A moves `center.panes.*` to
    /// `center.tab.*` and touches neither of the keys `TerminalPaneCensus` enumerates, so it
    /// cannot reach the orphan sweep whatever order they run in, but `AppModel.bootstrap` still
    /// reaches for this store before it hands a store to `TerminalSessionStore`. That ordering is
    /// 2e3d6e3 written down: the sweep kills every tmux session whose pane id nothing can
    /// enumerate, there is no way to get a killed shell back, and the next phase does rewrite a
    /// key the census reads.
    ///
    /// One snapshot of the app's own domain feeds all three scans below, because
    /// `dictionaryRepresentation()` materialises the merged search list and this ran it three
    /// times on the main actor before the window was usable. See `DefaultsSnapshot`.
    private init() {
        let defaults = UserDefaults.standard
        var snapshot = DefaultsSnapshot.own(defaults, name: Bundle.main.bundleIdentifier)

        for tab in TabMigration.migrateAll(in: defaults, keys: snapshot.keys) {
            // Phase A's own writes, folded back in. The scan below reads the snapshot rather than
            // defaults, so without this a launch that migrated would file no tab at all and show
            // every migrated workspace unsplit.
            guard let data = defaults.data(forKey: tab.key) else { continue }
            snapshot[tab.key] = data
        }

        for (key, value) in snapshot
        where key.hasPrefix(TabDefaults.tabPrefix) {
            let rootID = String(key.dropFirst(TabDefaults.tabPrefix.count))
            guard let data = value as? Data,
                  let stored = StoredPaneArrangement(decoding: data),
                  // The kind, recovered from the pointer the record spells out for the root's own
                  // pane. A record naming no such content cannot be drawn.
                  let root = stored.contents.values.first(where: { $0.id == rootID }),
                  let arrangement = Arrangement(root: root, stored: stored) else {
                // Dropped, for the reason `TabMigration.migrate` drops one it cannot read: an
                // arrangement is the cheapest thing in this app to lose, and a key that fails
                // every launch forever is worse than no key. This used to be a bare `continue`
                // while the comment claimed the record was dropped, so the commonest way to make
                // one, a crash between the two lines of `apply` that write the new key and delete
                // the old, left a record naming a root that has left every pane sitting there for
                // good. Its panes live under the new key, so there is nothing here to lose.
                //
                // Not the sparing answer `TerminalPaneCensus` gives its own unreadable bytes, and
                // deliberately: what it spares is a tmux session nobody can get back, where this
                // is one tab's layout, held nowhere else, read by nothing else, and rewritten the
                // moment the user splits that content again.
                defaults.removeObject(forKey: key)
                continue
            }
            arrangements[rootID] = arrangement
        }

        for (key, value) in snapshot
        where key.hasPrefix(TabDefaults.stripPrefix) {
            let workspaceID = WorkspaceID(String(key.dropFirst(TabDefaults.stripPrefix.count)))
            guard let data = value as? Data,
                  let order = try? JSONDecoder().decode([PaneContent].self, from: data) else {
                // Dropped rather than kept, on the same terms as an unreadable arrangement above:
                // an order is the cheapest thing in this app to lose, it is held nowhere else, it
                // costs one drag to make again, and a key that fails every launch forever is worse
                // than no key. Losing it puts the strip back to conversations and then tools, which
                // is where it was before anybody dragged anything.
                defaults.removeObject(forKey: key)
                continue
            }
            stripOrders[workspaceID] = order
        }
    }

    // MARK: - Reading

    /// The strip, left to right.
    ///
    /// Everything the workspace has, minus whatever a tab has absorbed, in whatever order the user
    /// has dragged it into. `TabSet` states the first rule and `StripOrder` the second, and this is
    /// the only place either is asked, so a tab is in the strip once or not at all.
    func entries(in model: WorkspaceModel) -> [PaneContent] {
        let sessions = model.sessions.map(\.id)
        let tools = CenterTabStore.shared.tabs(for: model.workspace.id).map(\.id)
        return StripOrder.entries(
            sessions: sessions,
            tools: tools,
            claimed: claimed(sessions: sessions, tools: tools),
            stored: stripOrders[model.workspace.id] ?? []
        )
    }

    /// Writes down the order the user has just dragged the strip into.
    ///
    /// Only the interleaving lives here. Each kind's own order goes back to the store that owns it,
    /// which is the caller's job and not this one's: see `StripOrder` for why that matters, which is
    /// that a lost defaults file should cost the interleaving and not the order of the
    /// conversations within it.
    func reorder(_ drawn: [PaneContent], in model: WorkspaceModel) {
        let workspaceID = model.workspace.id
        guard let order = StripOrder.rewritten(
            drawn,
            sessions: model.sessions.map(\.id),
            tools: CenterTabStore.shared.tabs(for: workspaceID).map(\.id),
            stored: stripOrders[workspaceID] ?? []
        ) else { return }

        stripOrders[workspaceID] = order
        persistStrip(workspaceID)
    }

    /// Which tab the user is in, or nothing when the workspace has neither a conversation nor a
    /// tool tab to be in.
    ///
    /// Resolved rather than remembered, so a tab that has gone (its session archived, its tool tab
    /// closed, itself absorbed into another tab) cannot leave the column pointing at nothing. It
    /// deliberately does not write the answer back: a view body asks this, and a body may not
    /// mutate observed state.
    func selectedTab(in model: WorkspaceModel) -> PaneContent? {
        selectedTab(in: model, entries: entries(in: model))
    }

    /// The same answer for a caller that has just derived the strip and would rather not pay for
    /// it twice.
    ///
    /// `entries(in:)` maps the sessions, reads the tool tab list, works out what the tabs have
    /// absorbed and lays the user's own order over the result, and the tab strip needs the list
    /// itself as well as the selection. Asking through the parameterless overload above made every
    /// pass derive it once for the `ForEach` and again in here.
    func selectedTab(in model: WorkspaceModel, entries: [PaneContent]) -> PaneContent? {
        if let chosen = selected[model.workspace.id], entries.contains(chosen) { return chosen }

        // The active conversation, which is what the toolbar, the inspector and the pull request
        // button are already talking about. It can be a pane of a composite tab rather than a tab
        // of its own, in which case the tab holding it is the one to open on.
        if let active = model.activeSession.map({ PaneContent.chat($0.id) }) {
            if entries.contains(active) { return active }
            if let owner = entries.first(where: { claimedContents(of: $0).contains(active) }) {
                return owner
            }
        }
        return entries.first
    }

    private func persistStrip(_ workspaceID: WorkspaceID) {
        let defaults = UserDefaults.standard
        let key = TabDefaults.stripKey(workspaceID)
        guard let order = stripOrders[workspaceID], !order.isEmpty,
              let data = try? JSONEncoder().encode(order) else {
            return defaults.removeObject(forKey: key)
        }
        defaults.set(data, forKey: key)
    }

    /// A tab nobody has split is one pane carrying the id of the content at its root.
    func layout(of tab: PaneContent) -> SplitLayout {
        arrangements[tab.id]?.layout ?? SplitLayout(pane: tab.id)
    }

    func focusedPane(of tab: PaneContent) -> String {
        layout(of: tab).focus
    }

    /// What one pane of a tab is showing.
    ///
    /// Total, and that is the point. `CenterPaneStore.content` answered nil for a pane nobody had
    /// given anything to, and resolved that on the fly to the workspace's ACTIVE conversation,
    /// which is what made creating a session change what an untouched pane was showing: Split
    /// Right then Chat put the new session in both halves. A pane belongs to a tab now, so the
    /// answer it falls back to is that tab, and it does not move.
    func content(of pane: String, in tab: PaneContent) -> PaneContent {
        arrangements[tab.id]?.contents[pane] ?? tab
    }

    /// Whether a strip entry can be put in a pane beside another one.
    ///
    /// False for an entry that roots a split tab of its own. Absorbing one would mean grafting its
    /// whole subtree into another tree, `SplitLayout` has no operation for that, and inventing one
    /// here is how a stage slips. The gesture is declined and the menu item offering it is
    /// disabled rather than doing something surprising with the arrangement underneath.
    func canAbsorb(_ entry: PaneContent) -> Bool {
        arrangements[entry.id] == nil
    }

    /// What a tab has absorbed: everything in a pane of it that is not the content at its root.
    ///
    /// The same rule as `StoredPaneArrangement.claimedContents(root:)`, and not a call to it only
    /// because reaching that one means encoding the tree to a string first, and this is asked of
    /// every tab every time the strip is drawn.
    private func claimedContents(of tab: PaneContent) -> Set<PaneContent> {
        guard let arrangement = arrangements[tab.id] else { return [] }
        return Set(arrangement.layout.panes.compactMap { arrangement.contents[$0] })
            .subtracting([tab])
    }

    private func claimed(sessions: [SessionID], tools: [String]) -> Set<PaneContent> {
        var claimed: Set<PaneContent> = []
        for tab in sessions.map(PaneContent.chat) + tools.map(PaneContent.tool) {
            claimed.formUnion(claimedContents(of: tab))
        }
        return claimed
    }

    // MARK: - Picking a tab

    /// Picks a tab. **The one thing this never does is write a pane's content.**
    ///
    /// The whole arrangement under the tab comes forward with it, which is what a tab owning a
    /// pane tree means, and the pane the user was standing in a moment ago keeps whatever it was
    /// holding, because that pane belongs to the tab they have just left.
    ///
    /// A workspace still has one active session, because the toolbar, the inspector and the pull
    /// request button all speak about one conversation, so a tab whose focused pane is a chat says
    /// which one that is. A tab whose focused pane is a shell or a page says nothing about it and
    /// leaves the last answer standing, which is what clicking a terminal tab has always done.
    func select(_ tab: PaneContent, in model: WorkspaceModel) {
        // A selected tab remains clickable. Do not turn that click into an observed dictionary
        // mutation and a redraw of the strip and panes when the selection did not move.
        if selected[model.workspace.id] != tab { selected[model.workspace.id] = tab }
        adoptActiveSession(of: tab, in: model)
    }

    /// Next Tab and Previous Tab, which is the pointer-free way round the strip.
    ///
    /// The order is `entries(in:)`, which is what the strip draws and what a drag reorders, so
    /// the shortcut walks the tabs in the order they are seen rather than in the order they were
    /// opened. Which tab is next is `TabCycle` in the core, with the wrapping and the
    /// closed-tab case tested; what is here is the strip it asks about.
    func selectNextTab(offset: Int, in model: WorkspaceModel) {
        let tabs = entries(in: model)
        guard let next = TabCycle.next(from: selectedTab(in: model), in: tabs, offset: offset) else {
            return
        }
        select(next, in: model)
    }

    /// Brings something to the front by name: the tab it is, or the tab that has absorbed it.
    ///
    /// The door every "open this in the centre column" route goes through, replacing
    /// `CenterPaneStore.show(_:in:)`, which put the thing into whichever pane had the keyboard.
    /// Nothing is taken off a pane any more, so the guard those callers each carried (`isShowing`,
    /// so clicking a filename could not drag the review into the half the reader was typing in)
    /// lives here instead, once: something already visible in the tab in front is already in
    /// front, and nothing is moved or refocused.
    func reveal(_ content: PaneContent, in model: WorkspaceModel) {
        if let current = selectedTab(in: model),
           layout(of: current).panes.contains(where: { self.content(of: $0, in: current) == content }) {
            return
        }

        let entries = entries(in: model)
        if entries.contains(content) { return select(content, in: model) }

        guard let owner = entries.first(where: { claimedContents(of: $0).contains(content) }),
              let pane = layout(of: owner).panes
                  .first(where: { self.content(of: $0, in: owner) == content })
        else { return }

        selected[model.workspace.id] = owner
        focus(pane, in: owner, of: model)
    }

    /// A pane the user clicked into. No focus request: it already has the keyboard, and asking for
    /// it again mid-click is how a click lands twice.
    ///
    /// It moves the active session where picking a tab does, and for the same reason: a composite
    /// tab holding two conversations has to point the toolbar at the one the caret is in.
    func focus(_ pane: String, in tab: PaneContent, of model: WorkspaceModel) {
        if var arrangement = arrangements[tab.id], arrangement.layout.focus != pane,
           arrangement.layout.setFocus(pane) {
            arrangements[tab.id] = arrangement
            persist(tab.id)
        }
        adoptActiveSession(of: tab, in: model)
    }

    /// Only when it moved. Every click into a pane comes through here, and assigning an identical
    /// value is still a mutation as far as Observation is concerned: `WorkspaceModel.reloadSessions`
    /// is the note about what that costs, an invalidation that reaches every pane of the column.
    private func adoptActiveSession(of tab: PaneContent, in model: WorkspaceModel) {
        guard case .chat(let sessionID) = content(of: focusedPane(of: tab), in: tab),
              model.activeSessionID != sessionID else { return }
        model.activeSessionID = sessionID
    }

    // MARK: - Panes

    /// Splits one pane of a tab and shows `content` in the half that opens. Returns the new pane.
    ///
    /// `content` nil means the pane's own, which is what duplicating a pane asks for. `before`
    /// puts the new content on the leading or top side instead, which is what a tab let go over
    /// that edge of a pane means; the two are placed in one step rather than by splitting and then
    /// overwriting, so a tool is never even momentarily in two panes at once.
    @discardableResult
    func split(
        tab: PaneContent,
        pane: String? = nil,
        axis: SplitAxis,
        showing content: PaneContent? = nil,
        before: Bool = false
    ) -> String? {
        var arrangement = arrangements[tab.id]
            ?? Arrangement(root: tab, layout: SplitLayout(pane: tab.id), contents: [tab.id: tab])
        let target = pane ?? arrangement.layout.focus
        let placed = content ?? arrangement.contents[target] ?? tab

        guard arrangement.canHold(placed), placed == tab || canAbsorb(placed) else { return nil }

        let opened = newID()
        guard arrangement.layout.split(target, axis: axis, into: opened) else { return nil }

        if before {
            arrangement.contents[opened] = arrangement.contents[target] ?? tab
            arrangement.contents[target] = placed
            _ = arrangement.layout.setFocus(target)
        } else {
            arrangement.contents[opened] = placed
            // Every pane of a split tab carries an explicit pointer. That is what retires the on
            // the fly fallback, and it is also what lets the root's kind be recovered at load.
            if arrangement.contents[target] == nil { arrangement.contents[target] = tab }
        }

        arrangements[tab.id] = arrangement
        persist(tab.id)
        return opened
    }

    /// Points one pane of a tab at something else: a tab let go over the middle of it, or the
    /// keystroke that puts the conversation back where the review was.
    ///
    /// An unsplit tab has no pane to repoint. Its one pane IS the tab, so showing something else
    /// in it means picking that other tab, and picking a tab is the one thing here that never
    /// writes a pane. That is the inversion, stated where `CenterPaneStore.show` used to break it.
    func replace(pane: String, of tab: PaneContent, with content: PaneContent, in model: WorkspaceModel) {
        guard var arrangement = arrangements[tab.id] else { return select(content, in: model) }
        guard arrangement.contents[pane] != content, arrangement.canHold(content),
              canAbsorb(content) else { return }

        arrangement.contents[pane] = content
        _ = arrangement.layout.setFocus(pane)
        arrangements[tab.id] = arrangement

        // Repointing the root's last pane takes the root out of the tab as surely as closing that
        // pane would, so it is settled the same way.
        if let stored = arrangement.stored {
            apply(TabSurgery.settle(stored, root: tab), to: tab, in: model.workspace.id)
        }
        adoptActiveSession(of: selected[model.workspace.id] ?? tab, in: model)
    }

    /// Closes one pane. False means it was the only one, which is a column that cannot be closed:
    /// the strip's own close buttons are how a workspace loses a conversation or a tool.
    ///
    /// **Closing a pane ejects, it never destroys**, and nothing here has to arrange that. The
    /// pane's pointer goes, no tab claims what it held any more, and `TabSet.entries` hands it
    /// back to the strip as an unsplit tab of its own on the next pass. See `TabSurgery`, which is
    /// where the rest of that decision lives.
    @discardableResult
    func close(pane: String, in tab: PaneContent, of workspaceID: WorkspaceID) -> Bool {
        guard let stored = arrangements[tab.id]?.stored else { return false }
        let outcome = TabSurgery.closePane(pane, in: stored, root: tab)
        guard outcome != .unchanged else { return false }
        apply(outcome, to: tab, in: workspaceID)
        return true
    }

    /// Moves one pane of a tab beside another pane of the same tab, keeping its id.
    ///
    /// **Nothing here touches `contents`, and that is the point.** The map is keyed by pane id, no
    /// pane appears and none goes, so a move is the one edit to an arrangement `TabSurgery` has
    /// nothing to answer about: no tab is left rooted on something that has left, and nothing is
    /// handed back to the strip. `SplitLayout.move` is where the tree work and the reasoning are.
    ///
    /// It follows that the live views do not move either. `CenterPanesView` positions its panes
    /// flat from the frames the tree computes, keyed by pane id, so a rearranged tree changes
    /// where a pane is drawn and never which view is drawing it. A moved terminal keeps the shell
    /// it had and a moved browser keeps the page it had loaded, scroll position and history
    /// included, because neither view is rebuilt and neither is reparented.
    @discardableResult
    func move(
        pane: String, beside target: String, axis: SplitAxis, before: Bool,
        in tab: PaneContent, of model: WorkspaceModel
    ) -> Bool {
        guard var arrangement = arrangements[tab.id],
              arrangement.layout.move(pane, beside: target, axis: axis, before: before)
        else { return false }

        arrangements[tab.id] = arrangement
        persist(tab.id)
        // The moved pane took the keyboard, so the workspace's one active conversation follows it
        // wherever it landed, exactly as it does when a pane is clicked into.
        adoptActiveSession(of: tab, in: model)
        return true
    }

    /// Exchanges two panes of a tab. What a pane let go over the MIDDLE of another one means: see
    /// `SplitLayout.exchange` for why that is an exchange rather than the replacement a tab let go
    /// there would be.
    @discardableResult
    func exchange(
        pane: String, with other: String, in tab: PaneContent, of model: WorkspaceModel
    ) -> Bool {
        guard var arrangement = arrangements[tab.id],
              arrangement.layout.exchange(pane, with: other) else { return false }

        arrangements[tab.id] = arrangement
        persist(tab.id)
        adoptActiveSession(of: tab, in: model)
        return true
    }

    func setRatio(_ ratio: Double, at path: [Int], in tab: PaneContent) {
        guard var arrangement = arrangements[tab.id],
              arrangement.layout.setRatio(ratio, at: path) else { return }
        arrangements[tab.id] = arrangement
    }

    /// The divider updates its observable layout continuously, then writes the final shape once.
    /// Double-click and accessibility adjustments use the same boundary immediately.
    func persistRatio(in tab: PaneContent) {
        persist(tab.id)
    }

    /// Called when a session is archived or a tool tab is closed, so no pane is left sitting on a
    /// pointer to something that has gone.
    ///
    /// Every tab is walked rather than only the one in front, because a chat closed with Cmd+W can
    /// be a pane of a tab the user is not looking at, and a pane holding a dead pointer would show
    /// an empty state until something else happened to reload the workspace.
    ///
    /// No `WorkspaceModel`, because `CenterTabStore.close` has none to give.
    func forget(_ content: PaneContent, workspaceID: WorkspaceID) {
        for arrangement in arrangements.values {
            guard let stored = arrangement.stored else { continue }
            let outcome = TabSurgery.remove(content, from: stored, root: arrangement.root)
            apply(outcome, to: arrangement.root, in: workspaceID)
        }
        if selected[workspaceID] == content { selected[workspaceID] = nil }
    }

    /// Checks a workspace's tabs against what is actually there, on arrival.
    ///
    /// A session can be archived, or a tool tab closed, in a launch that is not this one: the
    /// stores that would have called `forget` were not running. Without this a restored pane sits
    /// on a dead pointer showing an empty state, and the arrangement it is part of never heals.
    ///
    /// **Both lists are handed over as an answer or as doubt, never flattened.** `TabReconciliation`
    /// carries the reasoning and the tests; the part that belongs here is that neither store can be
    /// asked to guess on its behalf. `model.sessions` is empty until the `Store` actor comes back,
    /// and `CenterTabStore.tabs(for:)` is empty both for a workspace with no tool tabs and for one
    /// whose stored list would not decode.
    ///
    /// Called from `CenterColumnView` after `WorkspaceModel.onAppear`, which is what makes the
    /// first of those an answer rather than doubt on the first visit of a launch. Its own task
    /// loads the tool tabs before it awaits, so both are settled by the time this runs.
    func reconcile(in model: WorkspaceModel) {
        let workspaceID = model.workspace.id
        let tabs = CenterTabStore.shared

        var stored: [PaneContent: StoredPaneArrangement] = [:]
        for arrangement in arrangements.values {
            stored[arrangement.root] = arrangement.stored
        }

        let dead = TabReconciliation.dead(
            in: stored,
            sessions: model.hasReadSessions ? model.sessions.map(\.id) : nil,
            tools: tabs.hasReadTabs(for: workspaceID) ? tabs.tabs(for: workspaceID).map(\.id) : nil
        )
        for content in dead {
            forget(content, workspaceID: workspaceID)
        }
    }

    // MARK: - Writing a tab down

    /// Files what `TabSurgery` decided, and moves the selection with it when the tab the user is
    /// in is the one that changed name or went away.
    private func apply(_ outcome: TabSurgery.Outcome, to tab: PaneContent, in workspaceID: WorkspaceID) {
        switch outcome {
        case .unchanged:
            return

        case .updated(let root, let stored):
            guard let arrangement = Arrangement(root: root, stored: stored) else { return }
            arrangements[root.id] = arrangement
            // The new key first and the old key second, never the other way round. Between these
            // two lines the arrangement exists twice, which the next launch resolves; the other
            // way round it would exist nowhere. Same discipline as `TabMigration.migrate`.
            persist(root.id)
            if root != tab {
                arrangements[tab.id] = nil
                UserDefaults.standard.removeObject(forKey: TabDefaults.tabKey(tab.id))
                if selected[workspaceID] == tab { selected[workspaceID] = root }
            }

        case .dissolved(let remaining):
            arrangements[tab.id] = nil
            UserDefaults.standard.removeObject(forKey: TabDefaults.tabKey(tab.id))
            if selected[workspaceID] == tab { selected[workspaceID] = remaining }
        }
    }

    private func persist(_ rootID: String) {
        let defaults = UserDefaults.standard
        let key = TabDefaults.tabKey(rootID)

        // An unsplit tab is the default, so it is stored as nothing at all rather than as a record
        // saying so.
        guard let arrangement = arrangements[rootID], arrangement.layout.paneCount > 1,
              let data = arrangement.stored?.encoded else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
