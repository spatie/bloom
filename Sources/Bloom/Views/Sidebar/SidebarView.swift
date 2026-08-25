import SwiftUI
import BloomCore

/// The left column: where you can go, every project with its workspaces, and a status bar that
/// stays put.
///
/// A real `List` with `.listStyle(.sidebar)`, not a `ScrollView` over a `LazyVStack`. The list
/// brings the source list treatment that was previously hand-drawn and always slightly wrong:
/// AppKit selection (accent when the window is key, grey when it is not), the standard row
/// insets, and keyboard navigation between rows.
///
/// The projects are NOT sections of it. They were, and a section is what a source list normally
/// wants, but `onMove` on a `ForEach` of `Section`s moves nothing: a section header is not a row
/// the outline will pick up, so a project could not be dragged at all. The pane is one flat run of
/// rows instead, with a single `onMove` over it, and what a project header used to get from being
/// a section (its spacing, and its place in the outline as something that CONTAINS the rows below
/// it) `RepoHeaderRow` now says for itself, in a padding and in words. See `move(from:to:)`, and
/// `RepoHeaderRow.name` for what an outline row can and cannot be told by hand.
///
/// There is no account row. Bloom is local and single user, so a row naming the logged-in Mac
/// user said nothing, and on macOS `Menu { } label: { }` with `.borderlessButton` throws the
/// custom label away and draws only the indicator, which is why it rendered as a lone letter.
struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether this window is the one being used, which is what tells a loud selection from a
    /// resting one. See `selectionFill(for:)` for what this can and cannot say.
    @Environment(\.controlActiveState) private var activeState
    /// The window's undo manager. Only a view can see it, and `AppModel` is where the archive
    /// that wants it happens, so the sidebar hands it over. Any view in the window would do; this
    /// is the one that is always on screen.
    @Environment(\.undoManager) private var undoManager

    @State private var renaming: WorkspaceID?
    @State private var filter: SidebarFilter = .all

    /// Whether the projects the owner has hidden are in the list.
    ///
    /// A preference and not this window's state, which is the difference between it and `filter`
    /// above. The filter is a question you ask of the pane for a moment; hiding a project is a
    /// decision about what you want to see from now on, and a switch that undid it on every launch
    /// would make hiding something you have to keep doing. It is also the one route back to a
    /// hidden project. See `ProjectVisibility.showsHiddenKey`, which the status bar's own menu
    /// binds to the same key, so the two views cannot disagree.
    @AppStorage(ProjectVisibility.showsHiddenKey) private var showsHiddenProjects = false

    /// What the list itself thinks is selected. See the `onChange` pair below for why this is not
    /// bound straight to the model.
    @State private var listSelection: SidebarSelection?

    /// The grouped, filtered, sorted list the rows are drawn from.
    ///
    /// Derived state held in `@State` rather than recomputed in `body`, with the three inputs it
    /// depends on invalidating it explicitly below. See `SidebarRepoGroup` for why.
    @State private var groups: [SidebarRepoGroup] = []

    /// The same groups flattened into the run of rows the list draws, held rather than derived in
    /// `body` for the same reason `groups` is, and because the drag reads it back to work out what
    /// was moved. It is written in the same breath as `groups`, so the two can never disagree
    /// about what is on screen.
    @State private var paneRows: [SidebarPaneRow] = []

    /// What the status bar says instead of the running count, briefly, after a drag that could not
    /// land where it was let go. See `move(from:to:)`.
    ///
    /// Stamped rather than held as the sentence alone, so that saying the same thing twice is two
    /// sayings: two drops refused in the same project produce the same words, and a note keyed to
    /// the words would have the second one taken away on the first one's clock.
    @State private var reorderNote: ReorderNote?

    private struct ReorderNote: Equatable {
        var id = UUID()
        var sentence: String
    }

    /// Whether the pane has finished arriving, so the first fill is not animated.
    ///
    /// Session restore reads every project's `collapsed` flag out of the store after this view
    /// first draws, so without this a window that opens with two projects folded would unfold and
    /// refold them in front of the user. Same shape as `SessionTabsView`'s settle window, and for
    /// the same reason.
    @State private var hasSettled = false

    /// Which rows have just been added to the list, so they can fade in rather than appear. The
    /// rules for what counts as "just added" are `RowArrival`'s, and they are the same rules
    /// Home's list uses.
    @State private var arrival = RowArrival<WorkspaceID>()

    var body: some View {
        List(selection: $listSelection) {
            Section {
                navRow(.home, title: "Home", icon: "house")
                navRow(.search, title: "Search", icon: "magnifyingglass")
                // Third rather than second, and permanent rather than appearing once something has
                // been archived. A row that comes and goes is a row nobody learns the position of,
                // and this one is worth finding when a database has grown rather than only when
                // somebody happens to remember it exists.
                navRow(.archive, title: "Archive", icon: "archivebox")
            }

            // A plain row rather than a `Section` header, because the things it heads are
            // themselves sections and a list cannot nest one inside another. It carries no tag
            // and refuses selection, so it stays a label. Home and Search keep their own section
            // above it, which is what stops them reading as the first two projects.
            SidebarProjectsHeader(onAddProject: addProject)
                .selectionDisabled()
                .listRowSeparator(.hidden)

            // One `ForEach` over every project and every workspace, rather than a `Section` per
            // project, and the reason is the `onMove` at the foot of it. `onMove` on a `ForEach`
            // of `Section`s moves nothing at all: a section header is not a row the outline will
            // pick up, so the projects could not be dragged while each was a section of its own,
            // and there is no second `onMove` that reaches them. One flat run is the shape the
            // mechanism can move, and it moves both things: the source offset is what says
            // whether a project or a workspace was picked up. See `SidebarReorder.destination`.
            ForEach(paneRows) { row in
                switch row {
                case .project(let group):
                    RepoHeaderRow(
                        repo: group.repo,
                        hasUnreadWork: group.hasUnreadWork,
                        workspaceCount: group.workspaces.count,
                        onCreateWorkspace: presentCreate
                    )
                    // A project is never the selection. The pane selects work, not the folder the
                    // work is in, and this row carries no tag. Refusing selection does NOT refuse
                    // the drag, which is the whole reason the projects can be reordered at all.
                    .selectionDisabled()
                case .workspace(let workspace, let projectName):
                    // The fill and the ink are the same two lines every selectable row carries,
                    // and they are applied in `workspaceRow` rather than here: written inline,
                    // this `switch` stopped type checking in reasonable time.
                    workspaceRow(workspace, projectName: projectName)
                case .subagent(let subagent, let workspaceID, _):
                    SubagentSidebarRow(row: subagent)
                        // A row with no file to open refuses selection rather than taking it and
                        // showing an empty pane, which is the worse of the two.
                        .selectionDisabled(!subagent.opensOutput)
                        // Never something to pick up. A subagent has no place in the pane of its
                        // own: it is where it is because of what spawned it.
                        .moveDisabled(true)
                        .tag(SidebarSelection.subagent(workspaceID, subagent.id))
                        // A subagent that CAN be selected selects like everything else in the
                        // pane. One of these left on the system accent would have put the second
                        // blue straight back, one rung further in.
                        .listRowBackground(
                            selectionFill(for: .subagent(workspaceID, subagent.id))
                        )
                        .selectedRowInk(
                            isEmphasized: isEmphasized(.subagent(workspaceID, subagent.id))
                        )
                case .pending(let pending):
                    // A workspace that does not exist yet, so there is nothing to select, nothing
                    // to open and nothing to write a `sort_order` onto. Refused here and again in
                    // `SidebarReorder.destination`, on the same belt-and-braces footing as the
                    // notice below. It fades in like any other row that turns up: the tracker was
                    // handed its id in `regroup`, which is also what stops the stored row fading
                    // in over the top of it a moment later. See `PendingWorkspaceRow`.
                    PendingWorkspaceRow(pending: pending)
                        .arrivingRow(arrival.isArriving(pending.id))
                        .selectionDisabled()
                        .moveDisabled(true)

                case .notice:
                    // A sentence about a project, so it is neither selectable nor something to
                    // pick up. `SidebarReorder` refuses it a second time, in case the outline
                    // offers it anyway.
                    SidebarEmptyNoticeRow(isFiltered: filter != .all)
                        .selectionDisabled()
                        .moveDisabled(true)
                }
            }
            // The list's own row reordering, which is `NSOutlineView`'s: the insertion line, the
            // drag image, the autoscroll at the pane's edges, the snap back on a cancel and the
            // settle on drop are all AppKit's, and none of it is drawn here.
            .onMove(perform: move)
        }
        // The list draws its own row height, and that is left to it. Its selection is not.
        //
        // Selection: the fill is Bloom's, painted through `listRowBackground` on the one row that
        // is selected. This paragraph used to argue the other way, that a source list selection is
        // a system affordance and the brand is everywhere else. It was right that repainting the
        // row costs something and wrong about how much. Keyboard navigation is untouched, because
        // a background is not a behaviour. The inversion of the row's ink is not lost either, it
        // is simply ours now: `selectedRowInk` sets `backgroundProminence` itself, and everything
        // that reads it goes on reading it. What is genuinely coarser is the dimming, and
        // `selectionFill(for:)` says exactly how.
        //
        // What it did cost was the pane disagreeing with the window it is in. Every other list
        // here goes through `RowBackground`, whose emphasized fill is `Palette.accentFill`, and
        // the very same workspaces are drawn on Home by one of them. So one workspace was Spatie
        // Blue in the middle of the window and the user's own accent on the left, and a Mac set
        // to Graphite had a grey sidebar selection in an app with a teal one four hundred points
        // to the right. Photographed both ways: `--snapshot-gallery --gallery sidebar-selection`.
        //
        // This is the same opinion `Palette.accent` already holds and documents, held in one more
        // place rather than decided afresh. The rest of the accent's work in this window, the
        // focus ring, the caret, the text selection and a selected tab, is not ours and is
        // untouched.
        //
        // Row height: 32 points, where `Metrics.rowHeight` is 28 and the reference render is 28
        // as well. It is not ours to set. `listRowInsets`, an explicit `frame(height:)` on the
        // row, `defaultMinListRowHeight` and `controlSize` were each tried and each captured, and
        // all four left the pitch at exactly 32; `listRowInsets(leading:)` did not even move the
        // rows sideways. Reaching 28 means giving up `.listStyle(.sidebar)`, and with it the
        // selection above, keyboard navigation and the standard insets. Four points is not worth
        // that. What was in reach was making the rhythm EVEN, which is what a project header's
        // own top padding is spent on. See `SidebarMetrics.headerLead`.
        .listStyle(.sidebar)
        // What puts the fold back.
        //
        // A `List` animates nothing on its own: rows arrive and leave in whatever transaction the
        // data change happened in, and `repo.collapsed` is written through an actor, so by the
        // time `groups` changes the call that asked for it is long gone and there is no
        // `withAnimation` left to wrap. Keying the animation to a value is what reaches an
        // asynchronous change at all, and it has to sit HERE, on the list, rather than on the
        // section or on the rows: a `Section` is a layout instruction rather than a view, so a
        // modifier on it never reaches the table, and a `.transition` on a row is likewise never
        // read. Both were tried and both did exactly nothing. The list is the view that owns the
        // rows, so it is the view whose transaction has to carry the curve.
        //
        // The value is which projects are folded and nothing else. Adding, renaming or reordering
        // a workspace must not make the pane slide, and a running agent rewrites its diff stat
        // every few seconds, which would otherwise animate the whole column once a second.
        .animation(foldMotion, value: foldedProjects)
        // Hiding and unhiding, which is a different curve from folding because it is a different
        // change: a fold hides rows the list still holds, and this inserts or removes them. The
        // value is the projects that are hidden and the switch that decides whether being hidden
        // takes a row out of the pane at all, so both halves of the one gesture reach the table
        // through the same transaction. See `ProjectVisibilityMotion`, which is where the two
        // halves are told apart.
        .animation(visibilityMotion, value: hiddenProjects)
        .animation(visibilityMotion, value: showsHiddenProjects)
        // A subagent's row leaving when its work is done, which is another insertion or removal
        // and so another reflow, at the one length this pane confirms anything in.
        //
        // The value is WHICH subagents have rows and nothing about what those rows say. A running
        // subagent's readout changes about once a second, and animating on the rows themselves
        // would put the whole column into a 220 millisecond transaction on every tick of every
        // fan-out, which is the same trap the fold above is keyed away from.
        .animation(subagentMotion, value: subagentIdentities)
        .settlesArrivals($arrival)
        // The note takes itself back, and each one is on its own clock.
        .task(id: reorderNote) {
            guard reorderNote != nil else { return }
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            reorderNote = nil
        }
        .overlay {
            if app.repos.isEmpty, app.isLoaded {
                noProjects
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarStatusBar(filter: $filter, note: reorderNote?.sentence)
        }
        // Keyed to `isLoaded` rather than run once, because the projects arrive from the store
        // after the first draw. Timing the settle from an empty pane would let the whole restored
        // set of folds animate as it lands.
        .task(id: app.isLoaded) {
            hasSettled = false
            guard app.isLoaded else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            hasSettled = true
        }
        .onChange(of: app.repos, initial: true) { _, _ in regroup() }
        .onChange(of: app.workspaces) { _, _ in regroup() }
        // Rebuilds the run but not the groups. A subagent's row changes about once a second while
        // one is running, and regrouping on that would filter and sort every project's workspaces
        // once a second for the whole of a fan-out.
        .onChange(of: app.subagentRows) { _, _ in reflow() }
        // A create appearing, and the same row being retired when the stored one lands. The run
        // and not the groups, for the same reason: a workspace being cut changes no project's
        // membership, its filtering or its order.
        //
        // `reflow` alone would leave the arrival tracker never told about the id, so the stored
        // row would fade in on top of the row it is replacing. `regroup` is what feeds it, so this
        // one goes through the full rebuild: a create is a handful of times an hour, not once a
        // second, and the cost that argument is about is not here.
        .onChange(of: app.pendingWorkspaces) { _, _ in regroup() }
        // Rescoped, so widening the filter is not forty rows fading in at once. See `RowArrival`.
        .onChange(of: filter) { _, _ in regroup(rescoped: true) }
        // NOT rescoped, unlike the filter above, and the difference is what the two switches do.
        // A filter is a question you ask of rows that were always there. This one inserts project
        // headers at several depths at once, and a row that is arriving has no old position to
        // travel from: without the fade it slides in from wherever the table decides. The reflow
        // carries the rows that stay and `RowArrival` carries the ones that turn up, which is what
        // `ProjectVisibilityMotion.fadesArrivals` says and is the whole difference between this
        // reading as a list rearranging and as a list flickering.
        .onChange(of: showsHiddenProjects) { _, _ in
            regroup(rescoped: !ProjectVisibilityMotion.filterToggle(reduceMotion: reduceMotion)
                .fadesArrivals)
        }
        .onChange(of: listSelection) { _, _ in commitSelection() }
        // Delete on a selected row, which every Mac list that can delete binds and which
        // `onDeleteCommand` appeared nowhere in this app to answer. It is the menu item's own
        // action rather than a second path to the same place: `AppModel.archive` runs the git
        // safety check, says what is at stake when there is anything, and registers the undo, so
        // the reflex costs no more here than Shift+Cmd+Delete does from the menu.
        .onDeleteCommand {
            guard let id = app.selection.workspaceID,
                  let workspace = app.workspaces.first(where: { $0.id == id }) else { return }
            Task { await app.archive(workspace) }
        }
        // Rename from the menu bar, which reaches the field this list owns. A workspace this pane
        // is not drawing is ignored, so Home and the sidebar can both listen to one post.
        .onReceive(NotificationCenter.default.publisher(for: .bloomRenameWorkspace)) { note in
            guard let raw = note.userInfo?[Notification.bloomWorkspaceIDKey] as? String else {
                return
            }
            let id = WorkspaceID(raw)
            guard app.workspaces.contains(where: { $0.id == id }) else { return }
            renaming = id
        }
        // Moving off a row has to close whatever field was open on it, or the rename would carry
        // on editing a workspace that is no longer on screen.
        //
        // Closing it no longer throws away what was typed. This line used to be the second half of
        // an edit being eaten: the field went and the draft went with it, so selecting another
        // workspace mid rename silently lost the name. The row watches `renaming` and commits when
        // it is taken away, which is `InPlaceRename`'s `dismissed` ending. See `WorkspaceRow.end`.
        .onChange(of: app.selection, initial: true) { _, target in
            renaming = nil
            listSelection = target
        }
        // Not observed state, so this write invalidates nothing and is safe from an update.
        .onChange(of: undoManager, initial: true) { _, manager in
            app.undoManager = manager
        }
    }

    // MARK: - Motion

    /// `Motion.pane`, the same curve the centre tab strip moves on. A project folding is the same
    /// class of movement as a pane changing: short, flat, no overshoot. A fold with a spring of
    /// its own would read as a second app's idea of how fast this window goes.
    ///
    /// Dropped rather than slowed under Reduce Motion, matching every other call site, and
    /// dropped while the pane is still arriving.
    private var foldMotion: Animation? {
        guard !reduceMotion, hasSettled else { return nil }
        return Motion.pane
    }

    /// Which projects are folded, in order. Identity only: this must change when a project is
    /// folded or unfolded and at no other time.
    private var foldedProjects: [RepoID] {
        groups.filter(\.repo.collapsed).map(\.id)
    }

    /// Which projects are hidden, in order. The same discipline `foldedProjects` is under: this
    /// must change when one is hidden or unhidden and at no other time, or a diff stat landing
    /// mid animation would restart it.
    private var hiddenProjects: [RepoID] {
        groups.filter(\.repo.hidden).map(\.id)
    }

    /// The curve hiding, unhiding and the "Show hidden projects" switch all move on.
    ///
    /// One `Animation?` for all three, because the decision that differs between them is what
    /// CHANGES rather than how long it takes: with the switch on, hiding changes an opacity the
    /// header already draws and nothing is inserted, so the same transaction carries a contrast
    /// change; with it off, the same transaction carries an insertion or a removal and the rows
    /// below travel. See `ProjectVisibilityMotion` for that argument in full, and for why the
    /// length is `TranscriptMotion.arrival`'s rather than one chosen here.
    private var visibilityMotion: Animation? {
        guard hasSettled,
              let seconds = ProjectVisibilityMotion
                  .hideGesture(showingHidden: showsHiddenProjects, reduceMotion: reduceMotion)
                  .seconds
        else { return nil }
        return .easeOut(duration: seconds)
    }

    /// Which subagents have rows, per workspace. See the animation this keys.
    private var subagentIdentities: [WorkspaceID: [SubagentID]] {
        app.subagentRows.mapValues { $0.map(\.id) }
    }

    /// A subagent's row leaving. See `ProjectVisibilityMotion.subagentRemoval`.
    private var subagentMotion: Animation? {
        guard hasSettled,
              let seconds = ProjectVisibilityMotion.subagentRemoval(reduceMotion: reduceMotion)
                  .seconds
        else { return nil }
        return .easeOut(duration: seconds)
    }

    /// - Parameter rescoped: whether the list is being rebuilt because the filter moved, in which
    ///   case nothing in it counts as having arrived.
    private func regroup(rescoped: Bool = false) {
        groups = SidebarRepoGroup.build(
            repos: app.repos,
            workspaces: app.workspaces,
            filter: filter,
            showingHidden: showsHiddenProjects
        )
        paneRows = SidebarPaneRow.rows(
            groups, subagents: app.subagents(of:), pending: pending(in:)
        )
        // Every workspace the groups hold, a folded project's included. A fold hides rows rather
        // than removing them from the list, and unfolding one already has a movement of its own:
        // counting them out here would make every project the user reopens fade its contents in
        // underneath `foldMotion` doing the same job.
        //
        // In the same breath as the rows themselves, rather than from an `onChange` watching
        // `groups`, so a row and the fact that it is new land in one update and the row's first
        // drawn frame is the faded one.
        //
        // The workspaces being cut are counted among them, and that is the whole of what makes the
        // swap silent. `PendingWorkspace` carries the id the stored row will have, so by the time
        // that row arrives the tracker has already seen the id and does not read it as an arrival:
        // the row stops being a spinner and starts being a workspace, in place, without a second
        // settle under it. Left out, every create would fade its row in twice.
        let ids = groups.flatMap { $0.workspaces.map(\.id) } + app.pendingWorkspaces.map(\.id)
        if rescoped {
            arrival.adopt(ids)
        } else {
            arrival.absorb(ids)
        }
    }

    /// The workspaces being cut in one project, in the order they were asked for.
    ///
    /// Never filtered. `SidebarFilter` asks a question about a workspace's stored row (does it have
    /// unread work, does it have changes) and a row that does not exist yet has no answer to
    /// either, so a create made with Unread showing would vanish the moment it was asked for and
    /// reappear when it landed. A workspace the owner asked for a second ago is exactly what they
    /// are looking at the pane to see.
    private func pending(in repoID: RepoID) -> [PendingWorkspace] {
        app.pendingWorkspaces.filter { $0.repoID == repoID }
    }

    /// Redraws the run from the groups already computed, for a change that adds or removes rows
    /// without changing which workspaces are in the pane.
    private func reflow() {
        paneRows = SidebarPaneRow.rows(
            groups, subagents: app.subagents(of:), pending: pending(in:)
        )
    }

    // MARK: - Reordering

    /// Where a drag ended, in the order the rows are DRAWN in.
    ///
    /// The two numbers are the outline's, and they count every row in the run: project headers,
    /// the workspaces under them, and the sentence an empty project draws. They index nothing the
    /// store holds, and they do not even say which of the two things was dragged.
    /// `SidebarReorder.destination` answers that, `AppModel` writes the result, and nothing here
    /// knows about `sort_order`.
    ///
    /// The one case worth reading twice is a workspace let go over ANOTHER project. That drop
    /// cannot be refused: one `ForEach` means one insertion line and it is drawn wherever the
    /// pointer is, so the line appears in a project the row cannot join and the drop arrives here
    /// like any other. Two things then make it deliberate rather than broken. The row is clamped
    /// to the nearest place inside its OWN project, which is the end it was dragged towards, so a
    /// drag aimed past the last row lands on the last row and the movement goes the way the hand
    /// went. And the status bar says why, in the readout it already uses to talk about the pane,
    /// for as long as it takes to read and no longer.
    private func move(from: IndexSet, to: Int) {
        switch SidebarReorder.destination(rows: paneRows.map(\.identity), from: from, to: to) {
        case .nothing:
            break

        case .project(let id, let offset):
            Task { await app.reorderProjects(id: id, to: offset) }

        case .workspace(let projectID, let offsets, let offset, let landedOutside):
            guard let group = groups.first(where: { $0.id == projectID }) else { return }
            if landedOutside { note("Kept in \(group.repo.name)") }
            Task {
                await app.reorderWorkspaces(
                    in: group.repo, visible: group.workspaces, from: offsets, to: offset
                )
            }
        }
    }

    /// Says one thing in the status bar and then takes it back.
    ///
    /// Held in the sidebar rather than in the bar itself, because the bar is a readout and the
    /// thing worth saying happened up here. Written before the reorder is applied, so the sentence
    /// and the settle land in the same moment.
    private func note(_ sentence: String) {
        reorderNote = ReorderNote(sentence: sentence)
    }

    // MARK: - Selection

    /// The list works in optionals because clicking empty space deselects, and Bloom always has
    /// somewhere to be, so an empty selection is put back rather than passed on.
    ///
    /// Putting it back is the whole reason the list is not bound straight to the model through a
    /// hand-made binding. A binding whose setter drops `nil` looks like it refuses the
    /// deselection, but the table has already cleared its own highlight by then and nothing
    /// invalidates it again, so the row went blank while the detail pane carried on showing the
    /// workspace. Writing the old value back into the list's own state is what redraws it.
    ///
    /// Running here rather than in a binding setter also keeps the model write out of the table's
    /// selection callback, which is what AppKit means by a reentrant delegate operation.
    private func commitSelection() {
        guard let listSelection else {
            listSelection = app.selection
            return
        }
        app.selection = listSelection
    }

    /// One workspace in the pane, with the fill and the ink the top level rows also take.
    private func workspaceRow(_ workspace: Workspace, projectName: String) -> some View {
        let target = SidebarSelection.workspace(workspace.id)
        return SidebarWorkspaceRow(
            workspace: workspace,
            arrival: arrival,
            projectName: projectName,
            renaming: $renaming
        )
        .tag(target)
        // The same fill the three top level rows take. A row of one kind selecting in one blue and
        // a row of another kind in a second was the whole complaint.
        .listRowBackground(selectionFill(for: target))
        .selectedRowInk(isEmphasized: isEmphasized(target))
    }

    /// One of the three places the pane can take you, as a row of the list.
    ///
    /// The mark is inked by `SidebarNavRow` rather than left to the label, and that is the second
    /// half of the "two kinds of blue" this file was changed for. A `Label` in a source list draws
    /// its symbol in `controlAccentColor`, so Search and Archive were the user's blue sitting a
    /// row away from a selection that is now Bloom's: the same disagreement, one rung quieter.
    private func navRow(_ target: SidebarSelection, title: String, icon: String) -> some View {
        SidebarNavRow(title: title, icon: icon)
            .tag(target)
            .listRowBackground(selectionFill(for: target))
            .selectedRowInk(isEmphasized: isEmphasized(target))
    }

    /// The fill under one row, or nothing at all when that row is not the selection.
    ///
    /// Nothing rather than `Color.clear`, deliberately: a `listRowBackground` of clear REPLACES
    /// the list's own drawing, so an unselected row handed one loses its hover wash.
    ///
    /// It says loud or resting on the window alone, and that is one step coarser than AppKit was.
    /// The table dimmed its own highlight when the pane lost the KEYBOARD as well, so clicking a
    /// workspace and then typing in the composer used to quieten the row. Neither signal a
    /// `listRowBackground` can see says that. `backgroundProminence` is SwiftUI's own answer to
    /// the question and it is right inside a row, which is what still inverts the row's ink, but
    /// it arrives here increased whenever the row is selected and whatever the pane is doing.
    /// `@FocusState` on the list is no better: it reported focused with the table demonstrably
    /// not the first responder. Both were photographed before either was believed.
    ///
    /// So a selected row stays loud while this window is the one being used, and goes quiet when
    /// it is not. That is a fair thing for this pane to say: it is the window's navigation, and
    /// where you are does not stop being where you are because the caret moved to the composer.
    /// The row still says it more quietly the moment you look at another window.
    @ViewBuilder
    private func selectionFill(for target: SidebarSelection) -> some View {
        if listSelection == target {
            SidebarSelectionFill(isEmphasized: isEmphasized(target))
        }
    }

    /// Whether this row is the one wearing the loud fill.
    ///
    /// One answer, read by the fill and by the ink on top of it, and that is not tidiness. The
    /// first version of this asked two different questions: the fill asked the window whether it
    /// was active, and the ink asked `backgroundProminence`, which a `listRowBackground` does not
    /// move. So the pane painted Spatie Blue under a label that had never been told to invert, and
    /// Home came out near black on mid teal. A fill and the thing standing on it have to be one
    /// decision.
    private func isEmphasized(_ target: SidebarSelection) -> Bool {
        listSelection == target && activeState != .inactive
    }

    // MARK: - Empty

    private var noProjects: some View {
        ContentUnavailableView {
            Label("No projects yet", systemImage: "folder.badge.plus")
        } description: {
            Text("Point Bloom at a git repository to start running agents in it.")
        } actions: {
            Button("Choose a folder", systemImage: "folder", action: addProject)
                .buttonStyle(.borderedProminent)
                // Tinted explicitly, like every other prominent button in the app: untinted it
                // follows the system accent, which on a Mac set to Graphite is grey glass. See
                // `EmptyStateView`, which says the same over the same button.
                .tint(Palette.accentFill)
        }
    }

    // MARK: - Actions

    /// The create sheet lives in `RootView`, so every entry point (the toolbar, the repo header's
    /// `+`, the menu bar command) goes through one notification and behaves identically.
    private func presentCreate(in repo: Repo?) {
        renaming = nil
        NotificationCenter.default.post(name: .bloomNewWorkspace, object: repo)
    }

    private func addProject() {
        Task { await app.addProjectByAsking() }
    }
}

/// One of the pane's three top level rows, with its mark inked by hand.
///
/// A view of its own rather than a `Label` built in `SidebarView`, because reading
/// `backgroundProminence` needs somewhere to read it: the value is set on the ROW, so a function
/// returning a label cannot see it and a `SidebarView` that read it would be reading the whole
/// list's.
///
/// Neutral rather than `Palette.accent`. The accent is the right token for a tinted glyph and it
/// is a pair, so it would have been correct in both appearances, but it is a different member of
/// the ramp from the fill, and the pane would have gone from two blues to a blue and a green.
/// Colour in this pane already means three things: which project a tile belongs to, what a
/// workspace is doing, and where you are. A permanent tint on three rows means none of them. The
/// marks on the workspace rows below are already neutral, and these now match them.
struct SidebarNavRow: View {
    var title: String
    var icon: String

    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(
                    prominence == .increased ? Palette.textInverted : Palette.textSecondary
                )
        }
    }
}

/// What a selected row in the pane is painted with.
///
/// Two fills, and the difference between them is whether this window is the one being used.
///
/// The two values are `Palette.selectedEmphasized` and `Palette.selected`, which is exactly the
/// pair `RowBackground` uses. This view exists rather than a call to
/// `rowBackground(isSelected:isHovered:isFocused:)` because a `listRowBackground` is handed a view
/// to draw and not a modifier to apply to a row.
struct SidebarSelectionFill: View {
    /// Whether this window is the one being used. See `SidebarView.selectionFill(for:)` for why
    /// this is passed in rather than read from the environment here.
    var isEmphasized: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
            .fill(isEmphasized ? Palette.selectedEmphasized : Palette.selected)
            .padding(.horizontal, SidebarMetrics.selectionInset)
    }
}

extension View {
    /// Inverts a row's ink, and everything the row draws from it, while it wears the loud fill.
    ///
    /// Two things at once, on purpose. `foregroundStyle` is what the label and the symbol read, and
    /// `backgroundProminence` is what everything further in reads: the status mark, the running
    /// figure's breathing rings, the project tile and the diff stat all key off it, and every one
    /// of them already knows to switch to `Palette.textInverted` on a fill. The table used to set
    /// that environment value for us because the table drew the fill. Bloom draws it now, so Bloom
    /// sets it, and the two can never say different things about the same row.
    func selectedRowInk(isEmphasized: Bool) -> some View {
        environment(\.backgroundProminence, isEmphasized ? .increased : .standard)
            .foregroundStyle(isEmphasized ? Palette.textInverted : Palette.textPrimary)
    }
}
