import SwiftUI
import BloomCore

/// The left column: where you can go, every project with its workspaces, and a status bar that
/// stays put.
///
/// A real `List` with `.listStyle(.sidebar)`, not a `ScrollView` over a `LazyVStack`. The list
/// brings the source list treatment that was previously hand-drawn and always slightly wrong:
/// the standard row insets and keyboard navigation between rows. Not the selection's drawing,
/// which is the one thing taken back from it: AppKit's accent fill is what turned the selected
/// workspace blue on switching back to Bloom. See `SidebarSelectionFill`.
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.isSidebarFolded) private var isSidebarFolded
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @AppStorage(ProjectVisibility.showsEmptyKey) private var showsEmptyProjects = false

    /// Which shape the pane is in: projects with their workspaces, or sections by what each
    /// workspace needs. A preference for the same reason hiding a project is one, and the status
    /// bar binds the same key so the two cannot disagree. See `SidebarGrouping`.
    @AppStorage(SidebarGrouping.storageKey) private var storedGrouping = SidebarGrouping.fallback.rawValue
    @AppStorage(SidebarSectionOrder.storageKey)
    private var storedSectionOrder = SidebarSectionOrder.fallback.rawValue
    @AppStorage(SidebarPreferences.showsDiffStatsKey)
    private var showsDiffStats = SidebarPreferences.showsDiffStatsByDefault

    /// The sections the owner has folded away. Only Idle can be one. Window state rather than a
    /// preference: folding the long tail away to read the short one is a thing you do while
    /// working, not a decision about how the app looks.
    @State private var foldedStatusGroups: Set<SidebarStatusGroup> = []

    /// Which workspaces have their subagent rows folded away. Held here because the rows it
    /// controls are built here, and open by default: see `SubagentDisclosure`.
    @State private var subagentDisclosure = SubagentDisclosure()

    /// What the list itself thinks is selected. See the `onChange` pair below for why this is not
    /// bound straight to the model.
    @State private var listSelection: SidebarSelection?
    @State private var projectToReveal: RepoID?
    /// Whether the list's table is the first responder, and whether its window is key. Only the
    /// edge on the selection reads these; the fill is the same either way. See
    /// `SidebarKeyboardFocus`.
    @State private var listHasKeyboard = false
    @State private var windowIsKey = false
    @State private var archivePresentation = SidebarArchivePresentation()

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
    /// Updated with paneRows so a pending create cannot start its animation before its row exists.
    @State private var workspaceIdentities: Set<WorkspaceID> = []

    /// Which section each workspace is in, in the order the rows are drawn.
    ///
    /// What the movement between sections is animated on. `workspaceIdentities` is a set and so
    /// says nothing when a row changes section without joining or leaving the pane, which is
    /// exactly what happens when a turn ends: the row travelled from Working to Ready to read by
    /// being removed and reinserted, with nothing to animate it. This changes when, and only when,
    /// a row moves, so a status update that moves nothing puts the list into no transaction.
    @State private var statusArrangement: [String] = []
    /// The selected workspace that stays in Ready to read until it is left. See
    /// `SidebarReadingHold`.
    @State private var readingHold: WorkspaceID?

    /// What the status bar says instead of the running count, briefly, after a drag that could not
    /// land where it was let go. See `move(from:to:)`.
    ///
    /// Stamped rather than held as the sentence alone, so that saying the same thing twice is two
    /// sayings: two drops refused in the same project produce the same words, and a note keyed to
    /// the words would have the second one taken away on the first one's clock.
    @State private var reorderNote: ReorderNote?
    /// The New menu's "New workspace in" section, loaded here rather than in the menu because the
    /// archived workspaces it counts are a store read. See `RecentProjects.newMenu`.
    @State private var recentProjects: [Repo] = []
    /// The crew member whose Stop is waiting on an answer, and nil when nothing is being asked.
    ///
    /// Only ever set for one that is still working: stopping an agent that has already finished
    /// takes nothing away, and a dialog in front of a row nobody was going to lose is a dialog
    /// that teaches the reader to click through the next one.
    @State private var stoppingCrew: PendingCrewStop?

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

    /// The same tracker for the rows under a workspace: the subagents of a turn and the crew.
    ///
    /// Its own rather than the workspace one above, because the ids are of different types and
    /// because the two arrive on different clocks: a workspace turns up when somebody makes one, a
    /// subagent several at a time in the middle of a fan-out. Keyed by the workspace and the row's
    /// own id together, since a subagent's id comes from the CLI and two workspaces running at once
    /// are two id spaces. See `SidebarPaneRow.id`, which composes the same key for the same reason.
    @State private var childArrival = RowArrival<String>()

    var body: some View {
        answering(observing(pane))
    }

    /// A native sidebar list draws its last rows behind a bottom safe-area inset. Giving the
    /// footer its own height keeps those rows out of its transparent controls when the list fills.
    private var pane: some View {
        VStack(spacing: 0) {
            animating(list)
            statusBar
        }
    }

    private var statusBar: some View {
        SidebarStatusBar(
            filter: $filter,
            onCreateWorkspace: { presentCreate(in: $0) },
            onSelectProject: revealProject,
            onStartProject: startProject,
            note: reorderNote?.sentence
        )
    }

    /// The list itself. `body` is four steps (this, `animating`, `observing` and `answering`)
    /// because the chain as one expression was past what the CI runner's type checker would
    /// finish in a release build: green on this Mac, red there, three times.
    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $listSelection) {
                ForEach(topSections, id: \.rawValue) { section in
                    if section == .work {
                        workSection
                    } else {
                        conversationsSection
                    }
                }
            }
        // The native list owns row height, keyboard navigation and which row is selected. How the
        // selected row is drawn is `SidebarSelectionFill`'s, on each row, for the reason given there.
        //
        // Row height: 32 points, where `Metrics.rowHeight` is 28 and the reference render is 28
        // as well. It is not ours to set. `listRowInsets`, an explicit `frame(height:)` on the
        // row, `defaultMinListRowHeight` and `controlSize` were each tried and each captured, and
        // all four left the pitch at exactly 32; `listRowInsets(leading:)` did not even move the
        // rows sideways. Reaching 28 means giving up `.listStyle(.sidebar)`, and with it the
        // selection above, keyboard navigation and the standard insets. Four points is not worth
        // that. Project rows use the list's own vertical insets too.
            .listStyle(.sidebar)
            .animation(reduceMotion ? nil : Motion.pane, value: storedSectionOrder)
            .confirmation($stoppingCrew) { pending in
                Confirmation(
                    title: "Stop \(pending.name)?",
                    message: Self.crewStopMessage,
                    confirmLabel: "Stop",
                    cancelLabel: "Keep Working"
                )
            } onConfirm: { pending in
                Task { await stop(pending) }
            }
            .onChange(of: projectToReveal) { _, _ in scrollToProject(proxy) }
            .onChange(of: paneRows.map(\.id)) { _, _ in scrollToProject(proxy) }
        }
    }

    @ViewBuilder
    private var workSection: some View {
        if grouping == .projects, !groups.isEmpty {
            Section {
                sectionHeader(for: .work, title: "Projects")
                    .selectionDisabled()
                paneRowsList
            }
        } else if grouping == .status {
            Section {
                sectionHeader(for: .work, title: "Workspaces")
                    .selectionDisabled()
                paneRowsList
            }
        }
    }

    @ViewBuilder
    private var conversationsSection: some View {
        if filter == .all {
            Section {
                HStack {
                    Text("Conversations")
                        .font(Typo.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(Palette.textSecondary)
                        .reorderableSection(.conversations, order: $storedSectionOrder)
                    Spacer()
                    Button("New conversation", systemImage: "plus") {
                        NotificationCenter.default.post(name: .bloomNewConversationWorkspace, object: nil)
                    }
                    .labelStyle(.iconOnly)
                    .font(Typo.label)
                    .frame(width: Metrics.headerButton.width, height: Metrics.headerButton.height)
                    .buttonStyle(.plain)
                }
                .accessibilityAddTraits(.isHeader)
                .selectionDisabled()

                ForEach(app.ask.workspaceConversations, id: \.id) { chat in
                    ConversationSidebarRow(chat: chat)
                        .tag(SidebarSelection.conversation(chat.id))
                        .sidebarSelection(selectionStyle(for: .conversation(chat.id)))
                }
                .onMove { offsets, destination in
                    Task { await app.ask.reorderConversations(from: offsets, to: destination) }
                }
            }
        }
    }

    private func sectionHeader(for section: SidebarTopSection, title: String) -> some View {
        HStack {
            Text(title)
                .font(Typo.label)
                .fontWeight(.semibold)
                .foregroundStyle(Palette.textSecondary)
                .reorderableSection(section, order: $storedSectionOrder)
            Spacer()
        }
        .padding(.trailing, Metrics.inset + Metrics.spacingWide)
        .accessibilityAddTraits(.isHeader)
    }

    private var sectionOrder: SidebarSectionOrder {
        SidebarSectionOrder(rawValue: storedSectionOrder) ?? .fallback
    }

    private var topSections: [SidebarTopSection] {
        sectionOrder == .conversationsFirst ? [.conversations, .work] : [.work, .conversations]
    }

    /// The motion keyed to the list's values, one step of `body`. See `list`.
    private func animating(_ list: some View) -> some View {
        list
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
        // The value is which projects are folded and nothing else. Renaming or reordering
        // a workspace must not start a fold, and a running agent rewrites its diff stat
        // every few seconds, which would otherwise animate the whole column once a second.
        .animation(foldMotion, value: foldedProjects)
        // Observe the displayed project IDs alongside their dimmed state. With hidden projects
        // filtered out, `hiddenProjects` stays empty even as a project leaves. The preference
        // changes before `regroup` publishes the rows, so animating that switch misses the row
        // update too. Both values here come from the groups published with `paneRows`.
        .animation(visibilityMotion, value: hiddenProjects)
        .animation(visibilityMotion, value: projectIdentities)
        // Membership is published with the rows, after asynchronous creates, archives, deletes
        // and restores reach the model. A set ignores renames, status updates and reordering;
        // pending and stored workspaces share an id, so finishing a create does not reinsert it.
        .animation(workspaceMotion, value: workspaceIdentities)
        .animation(workspaceMotion, value: statusArrangement)
        // Project-free conversations are drawn outside `paneRows`, so workspace membership never
        // changes when one is archived. Key their membership to the same row-removal curve.
        .animation(workspaceMotion, value: conversationIdentities)
        // A subagent's row leaving when its work is done, which is another insertion or removal
        // and so another reflow, at the one length this pane confirms anything in.
        //
        // The value is WHICH subagents have rows and nothing about what those rows say. A running
        // subagent's readout changes about once a second, and animating on the rows themselves
        // would put the whole column into a 220 millisecond transaction on every tick of every
        // fan-out, which is the same trap the fold above is keyed away from.
        .animation(subagentMotion, value: subagentIdentities)
        // A crew member's row arriving when an agent starts one, on the same curve and for the
        // same reason: it is an insertion into the middle of a project's block, and the rows below
        // it travel. The value is WHICH crew members have rows, never what those rows say, so a
        // member moving between working and idle does not put the column into a transaction.
        .animation(subagentMotion, value: crewIdentities)
        // Opening or folding a workspace's subagent count. The identities above do not move when
        // this does: the same rows are in the pane either way, and this is the only thing that says
        // whether they are drawn.
        .animation(subagentMotion, value: subagentDisclosure)
        .settlesArrivals($arrival)
        .settlesArrivals($childArrival)
        // The note takes itself back, and each one is on its own clock.
        // Keyed on what can change the answer: a workspace started or archived, an archive
        // cleared out, and a project hidden, shown or removed.
        .task(id: NewMenuRecentKey(app: app)) {
            let archived = await app.archivedWorkspaces()
            recentProjects = RecentProjects.newMenu(app.repos, workspaces: app.workspaces + archived)
        }
        .task(id: reorderNote) {
            guard reorderNote != nil else { return }
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            reorderNote = nil
        }
        // A struct of its own rather than a closure here: written inline, it put `body` past what
        // the CI runner's type checker would finish, green on this Mac and red there.
        .toolbar {
            SidebarToolbar(
                isFolded: isSidebarFolded,
                onNewWorkspace: { presentCreate(in: nil) },
                onStartProject: startProject,
                onCreateWorkspace: { presentCreate(in: $0) },
                recentProjects: recentProjects
            )
        }
    }

    /// What the pane listens to: the model's changes, the filter, the selection and the menu bar.
    private func observing(_ pane: some View) -> some View {
        pane
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
        .task(id: app.isLoaded) {
            if app.isLoaded { await app.ask.open() }
        }
        .onChange(of: app.workspaces) { _, _ in regroup() }
        // The whole run changes shape, and nothing in it counts as having arrived: every row was
        // already on screen a moment ago, in another order. See the filter's own change below.
        .onChange(of: storedGrouping) { _, _ in
            foldedStatusGroups = []
            regroup(rescoped: true)
        }
        // Rebuilds the run but not the groups. A subagent's row changes about once a second while
        // one is running, and regrouping on that would filter and sort every project's workspaces
        // once a second for the whole of a fan-out.
        .onChange(of: app.subagentRows) { _, _ in reflow() }
        // The same rebuild for the same kind of change, and the groups are left alone for the same
        // reason: an agent starting or finishing changes no project's membership, its filtering or
        // its order. See `AppModel.crewRows`.
        .onChange(of: app.crewRows) { _, _ in reflow() }
        // An agent starting or stopping, or a question being asked or answered, moves a row between
        // the status view's sections without writing the workspace, so `app.workspaces` never
        // changes and nothing else would rebuild the run. The project view draws these as marks
        // on rows it already has, so it needs no rebuild.
        .onChange(of: app.runningWorkspaceIDs) { _, _ in if grouping == .status { reflow() } }
        .onChange(of: app.waitingWorkspaceIDs) { _, _ in if grouping == .status { reflow() } }
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
        .onChange(of: filter) { _, _ in
            archivePresentation.cancel()
            regroup(rescoped: true)
        }
    }

    /// The selection, the keyboard and the menu bar. Its own step for the reason `list` gives.
    private func answering(_ pane: some View) -> some View {
        pane
        .onAppear { SwitchProbe.attachSidebarSelection($listSelection) }
        .onDisappear {
            archivePresentation.cancel()
            SwitchProbe.attachSidebarSelection(nil)
        }
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
        .onChange(of: showsEmptyProjects) { _, _ in reflow() }
        .onChange(of: listSelection) { _, selected in
            app.highlightSidebarSelection(selected)
            if selected == nil { listSelection = app.selection }
        }
        .background {
            SidebarSelectionSync(
                selection: listSelection,
                onActivate: commitSelection,
                onFollow: follow
            )
            .allowsHitTesting(false)
        }
        .background {
            SidebarKeyboardFocus { hasKeyboard, isKey in
                listHasKeyboard = hasKeyboard
                windowIsKey = isKey
            }
            .allowsHitTesting(false)
        }
        // Delete on a selected row, which every Mac list that can delete binds and which
        // `onDeleteCommand` appeared nowhere in this app to answer. It is the menu item's own
        // action rather than a second path to the same place: `AppModel.archive` runs the git
        // safety check, says what is at stake when there is anything, and registers the undo, so
        // the reflex costs no more here than Shift+Cmd+Delete does from the menu.
        .onDeleteCommand { archiveSelectedRow() }
        // Rename from the menu bar, which reaches the field this list owns. A workspace this pane
        // is not drawing is ignored, so Home and the sidebar can both listen to one post.
        .onReceive(NotificationCenter.default.publisher(for: .bloomRenameWorkspace)) { note in
            beginRename(note)
        }
        // Moving off a row has to close whatever field was open on it, or the rename would carry
        // on editing a workspace that is no longer on screen.
        //
        // Closing it no longer throws away what was typed. This line used to be the second half of
        // an edit being eaten: the field went and the draft went with it, so selecting another
        // workspace mid rename silently lost the name. The row watches `renaming` and commits when
        // it is taken away, which is `InPlaceRename`'s `dismissed` ending. See `WorkspaceRow.end`.
        // Not observed state, so this write invalidates nothing and is safe from an update.
        .onChange(of: undoManager, initial: true) { _, manager in
            app.undoManager = manager
        }
    }

    // MARK: - The rows

    /// Which shape the pane is in, as the value rather than the stored string.
    private var grouping: SidebarGrouping {
        SidebarGrouping(rawValue: storedGrouping) ?? .fallback
    }

    /// Every row the pane draws, in one `ForEach`, in both shapes.
    ///
    /// One `ForEach` over every project and every workspace, rather than a `Section` per project,
    /// and the reason is the `onMove` at the foot of it. `onMove` on a `ForEach` of `Section`s moves
    /// nothing at all: a section header is not a row the outline will pick up, so the projects could
    /// not be dragged while each was a section of its own, and there is no second `onMove` that
    /// reaches them. One flat run is the shape the mechanism can move, and it moves both things: the
    /// source offset is what says whether a project or a workspace was picked up. See
    /// `SidebarReorder.destination`.
    ///
    /// The status view puts its own headings in the same run, for the same reason, and hands
    /// `onMove` nothing at all: there is no hand-chosen order to drop into when the sections are
    /// decided by what each agent is doing. See `SidebarGrouping.allowsReordering`.
    @ViewBuilder
    private var paneRowsList: some View {
        ForEach(paneRows) { row in
            paneRow(row)
                .environment(\.sidebarRowIndent, grouping == .projects ? SidebarMetrics.rowIndent : 0)
        }
        // The list's own row reordering, which is `NSOutlineView`'s: the insertion line, the
        // drag image, the autoscroll at the pane's edges, the snap back on a cancel and the
        // settle on drop are all AppKit's, and none of it is drawn here. Handed nothing in the
        // status view, which refuses the drag rather than accepting it and undoing it.
        .onMove(perform: reorderAction)
    }

    /// Whether a drag is offered at all, as the optional `onMove` takes rather than as a ternary in
    /// place: written inline the expression defeated the type checker outright.
    private var reorderAction: ((IndexSet, Int) -> Void)? {
        guard grouping.allowsReordering else { return nil }
        return { from, to in move(from: from, to: to) }
    }

    /// One row of the run, whichever kind it is.
    ///
    /// Its own function rather than a `switch` inside the `ForEach`: with the status heading added
    /// the builder had seven branches and the compiler stopped being able to type check it, which
    /// it reported as "failed to produce diagnostic for expression" rather than as anything useful.
    @ViewBuilder
    private func paneRow(_ row: SidebarPaneRow) -> some View {
        switch row {
        case .project(let group):
            RepoHeaderRow(
                repo: group.repo,
                isFirstProject: groups.first?.id == group.id,
                hasUnreadWork: group.hasUnreadWork,
                workspaceCount: group.workspaces.count,
                onCreateWorkspace: presentCreate
            )
            // A project is never the selection. The pane selects work, not the folder the
            // work is in, and this row carries no tag. Refusing selection does NOT refuse
            // the drag, which is the whole reason the projects can be reordered at all.
            .selectionDisabled()
        case .statusHeading(let group, let count, let isFolded):
            SidebarStatusHeadingRow(
                group: group,
                count: count,
                isFolded: isFolded,
                onToggleFold: group.isFoldable ? { toggleFold(group) } : nil
            )
            .selectionDisabled()
            .moveDisabled(true)
        case .workspace(let workspace, let projectName):
            workspaceRow(workspace, projectName: projectName)
        case .crew(let member, let workspaceID, _):
            CrewSidebarRow(row: member)
                // Faded in on its first frame, like every other row that turns up in the middle of
                // the pane. Innermost, on the drawing alone: a row that is fading in is still
                // selectable and still right clickable throughout.
                .arrivingRow(childArrival.isArriving(row.childKey ?? ""))
                // The owner's own way to be finished with a subagent, which the agent
                // above it has in `agent_stop` and the person watching it did not.
                .contextMenu {
                    Button("Stop Subagent") { askToStop(member, in: workspaceID) }
                }
                // Always selectable, unlike the subagent row below it: a crew member is a
                // conversation, so there is always something to open, whatever it is
                // doing and whether or not it is still running.
                //
                // Never something to pick up. A crew member is where it is because of the
                // worktree it shares, not because of an order anybody chose.
                .moveDisabled(true)
                .tag(SidebarSelection.crew(workspaceID, member.id))
                .sidebarSelection(selectionStyle(for: .crew(workspaceID, member.id)))
        case .subagent(let subagent, let workspaceID, _):
            SubagentSidebarRow(row: subagent)
                .arrivingRow(childArrival.isArriving(row.childKey ?? ""))
                // A row with no file to open refuses selection rather than taking it and
                // showing an empty pane, which is the worse of the two.
                .selectionDisabled(!subagent.opensOutput)
                // Never something to pick up. A subagent has no place in the pane of its
                // own: it is where it is because of what spawned it.
                .moveDisabled(true)
                .tag(SidebarSelection.subagent(workspaceID, subagent.id))
                .sidebarSelection(selectionStyle(for: .subagent(workspaceID, subagent.id)))
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

    /// Opens or folds one workspace's subagent rows.
    private func toggleSubagents(_ id: WorkspaceID) {
        subagentDisclosure.toggle(id)
        reflow()
    }

    private func toggleFold(_ group: SidebarStatusGroup) {
        if foldedStatusGroups.remove(group) == nil { foldedStatusGroups.insert(group) }
        reflow()
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

    /// Membership only, so renames, reordering and status updates do not trigger visibility motion.
    private var projectIdentities: Set<RepoID> {
        Set(groups.map(\.id))
    }

    private var conversationIdentities: Set<SessionID> {
        Set(app.ask.workspaceConversations.map(\.id))
    }

    /// Hidden projects still on screen, whose headers dim when "Show hidden projects" is on.
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

    /// Which crew members have rows, per workspace. See the animation this keys.
    private var crewIdentities: [WorkspaceID: [SessionID]] {
        app.crewRows.mapValues { $0.map(\.id) }
    }

    private var workspaceMotion: Animation? {
        guard hasSettled, !reduceMotion else { return nil }
        return .easeOut(duration: ProjectVisibilityMotion.seconds)
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
        paneRows = builtRows()
        childArrival.absorb(paneRows.compactMap(\.childKey))
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
        workspaceIdentities = Set(ids)
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
        paneRows = builtRows()
        // In the same breath as the rows, so a subagent's row and the fact that it is new land in
        // one update and its first drawn frame is the faded one. Nothing is fed here for a row that
        // is leaving: a row that goes has a place to go from, and the reflow underneath carries it.
        childArrival.absorb(paneRows.compactMap(\.childKey))
    }

    /// The run of rows, in whichever shape the pane is in.
    ///
    /// Both shapes are built from the same groups: `SidebarRepoGroup.build` has already applied the
    /// filter, the hidden projects preference and the stored order, so the status view inherits all
    /// three rather than asking its own version of any of them.
    private func builtRows() -> [SidebarPaneRow] {
        switch grouping {
        case .projects:
            return SidebarPaneRow.rows(
                groups,
                showingEmptyProjects: showsEmptyProjects,
                crew: app.crew(of:),
                subagents: app.subagents(of:),
                pending: pending(in:),
                showsSubagents: subagentDisclosure.shows
            )
        case .status:
            let names = Dictionary(
                groups.map { ($0.id, $0.repo.name) }, uniquingKeysWith: { first, _ in first }
            )
            let listing = SidebarStatusListing.build(
                workspaces: groups.flatMap(\.workspaces),
                holding: readingHold,
                status: status(of:)
            )
            // Written here rather than derived in `body`, in the same breath as the rows, so the
            // move and the value the move is animated on land in one update.
            statusArrangement = listing.sections.flatMap { section in
                section.workspaces.map { section.group.rawValue + ":" + $0.id.rawValue }
            }
            return SidebarStatusRows.rows(
                listing: listing,
                projectName: { names[$0] ?? "" },
                folded: foldedStatusGroups,
                crew: app.crew(of:),
                subagents: app.subagents(of:),
                pending: app.pendingWorkspaces,
                showsSubagents: subagentDisclosure.shows
            )
        }
    }

    private func revealProject(_ repo: Repo) {
        filter = .all
        storedGrouping = SidebarGrouping.projects.rawValue
        if repo.hidden { showsHiddenProjects = true }
        if !app.workspaces.contains(where: { $0.repoID == repo.id }) {
            showsEmptyProjects = true
        }
        projectToReveal = repo.id
    }

    private func scrollToProject(_ proxy: ScrollViewProxy) {
        guard let id = projectToReveal else { return }
        let rowID = "project:" + id.rawValue
        guard paneRows.contains(where: { $0.id == rowID }) else { return }
        proxy.scrollTo(rowID, anchor: .center)
        projectToReveal = nil
    }

    /// What one workspace amounts to, which is the same verdict its row's mark is drawn from.
    ///
    /// Asked here rather than inside `SidebarStatusListing` because two of its three inputs are the
    /// app's: whether an agent has a turn open, and whatever `gh` last said about the branch. The
    /// pull request is read out of the shared cache and never fetched, for the reason
    /// `WorkspaceRow` gives: a pane of thirty rows filling that cache would be thirty subprocesses.
    private func status(of workspace: Workspace) -> WorkspaceStatus {
        WorkspaceStatus.resolve(
            workspace: workspace,
            isRunning: app.isRunning(workspace),
            pullRequest: WorkspacePullRequests.shared.pullRequest(for: workspace.id),
            isAwaitingPermission: app.isAwaitingPermission(workspace),
            isStarting: app.isStarting(workspace)
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
            let visible = SidebarReorder.visibleProjects(in: paneRows.map(\.identity))
            Task { await app.reorderProjects(id: id, visible: visible, to: offset) }

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
    /// The native highlight gets a frame of its own before this changes the centre column.
    /// A newer click, external navigation or archive always wins over a pending activation.
    private func commitSelection(_ target: SidebarSelection, replacing previous: SidebarSelection) {
        guard listSelection == target, app.selection == previous else { return }
        if let id = target.workspaceID, !app.workspaces.contains(where: { $0.id == id }) {
            listSelection = app.selection
            return
        }
        app.selection = target
    }

    /// The menu bar asking for a rename, which reaches the field this list owns. A workspace this
    /// pane is not drawing is ignored, so Home and the sidebar can both listen to one post.
    private func beginRename(_ note: Notification) {
        guard let raw = note.userInfo?[Notification.bloomWorkspaceIDKey] as? String else { return }
        let id = WorkspaceID(raw)
        guard app.workspaces.contains(where: { $0.id == id }) else { return }
        renaming = id
    }

    /// The selection moving, wherever it moved from.
    ///
    /// Moving off a row has to close whatever field was open on it, or the rename would carry on
    /// editing a workspace that is no longer on screen. Closing it no longer throws away what was
    /// typed: the row watches `renaming` and commits when it is taken away, which is
    /// `InPlaceRename`'s `dismissed` ending. See `WorkspaceRow.end`.
    private func follow(_ target: SidebarSelection) {
        renaming = nil
        listSelection = target
        let hold = SidebarReadingHold.next(
            selection: target, current: readingHold, workspaces: app.workspaces
        )
        guard hold != readingHold else { return }
        readingHold = hold
        if grouping == .status { reflow() }
    }

    /// Delete on the selected row, from the keyboard.
    ///
    /// **A method rather than the closure it was, and the reason is a build that only fails on
    /// somebody else's machine.** Written inline it was two `guard`s and a pattern match inside a
    /// `body` that had grown three more animations and a second arrival tracker, and the whole
    /// expression stopped type checking in reasonable time: green here, red on the CI runner, which
    /// is slower and is the green that counts. Nothing about what it does changed.
    private func archiveSelectedRow() {
        guard let id = listSelection?.workspaceID,
              let workspace = app.workspaces.first(where: { $0.id == id }),
              isDrawn(workspace) else { return }
        archiveFromKeyboard(workspace)
    }

    /// Whether this workspace has a row in the pane right now, rather than being filtered out or
    /// folded away inside a project.
    private func isDrawn(_ workspace: Workspace) -> Bool {
        paneRows.contains { row in
            guard case .workspace(let shown, _) = row else { return false }
            return shown.id == workspace.id
        }
    }

    private func archiveFromKeyboard(_ workspace: Workspace) {
        let generation = archivePresentation.begin(workspaceID: workspace.id, source: .row)
        Task {
            defer { archivePresentation.finish(generation: generation) }
            await app.archive(workspace) { request in
                archivePresentation.present(request, generation: generation)
            }
        }
    }

    /// One workspace in the native sidebar list.
    private func workspaceRow(_ workspace: Workspace, projectName: String) -> some View {
        let target = SidebarSelection.workspace(workspace.id)
        return SidebarWorkspaceRow(
            workspace: workspace,
            arrival: arrival,
            projectName: projectName,
            // Only the status view, where no header above the row says which project this is.
            trailingRepo: grouping == .status
                ? app.repos.first { $0.id == workspace.repoID }
                : nil,
            isShowingSubagents: subagentDisclosure.shows(workspace.id),
            onToggleSubagents: { toggleSubagents(workspace.id) },
            showsDiffStats: showsDiffStats,
            renaming: $renaming,
            archivePresentation: $archivePresentation
        )
        .tag(target)
        .sidebarSelection(selectionStyle(for: target))
    }

    /// How `target`'s row says it is selected. Keyed to `listSelection`, the list's own answer,
    /// rather than `app.selection`, which lags it by a frame on purpose (see
    /// `SidebarSelectionActivation`): the fill has to land in the frame the click did.
    private func selectionStyle(for target: SidebarSelection) -> SidebarSelectionStyle {
        .resolve(
            isSelected: listSelection == target,
            listHasKeyboard: listHasKeyboard,
            windowIsKey: windowIsKey
        )
    }

    // MARK: - Empty

    // No empty state of its own. With no projects, Home in the middle of the window already says
    // so and carries the button that starts one, and a second "No projects yet" with a second
    // Start a project button in the sidebar was the same call to action printed twice on first
    // run. The Projects heading's `+` and the status bar's project browser are still here.

    // MARK: - Actions

    /// What the question says, as one string rather than four concatenations inside a view
    /// builder: the compiler timed out type-checking it in place, and the words are worth more
    /// here than in an expression.
    ///
    /// Consequences rather than "are you sure": what is lost is the turn, what survives is the
    /// work and the conversation, and the agent above it hears about it either way.
    private static let crewStopMessage =
        "It is working now, and the turn it is in the middle of is lost. Everything it has "
        + "already written in the worktree stays exactly as it is, and its conversation stays "
        + "here to read. The agent that started it is told."

    /// One crew member the owner has asked to stop, held while the question is on screen.
    ///
    /// The workspace travels with it because the row that asked is gone by the time the answer
    /// comes back: stopping is the one action here that removes the row it was started from.
    struct PendingCrewStop: Equatable {
        var sessionID: SessionID
        var workspaceID: WorkspaceID
        var name: String
    }

    /// Asks first only when there is something to lose.
    ///
    /// A member that has finished its turn is stopped on the spot: the row goes, the name is freed
    /// and nothing that was running stops, so a dialog would be asking about nothing. One that is
    /// working gets the question, because its turn dies with it.
    private func askToStop(_ member: CrewRow, in workspaceID: WorkspaceID) {
        let pending = PendingCrewStop(
            sessionID: member.id, workspaceID: workspaceID, name: member.name
        )

        switch member.state {
        case .running, .waiting: stoppingCrew = pending
        case .idle, .failed, .cancelled: Task { await stop(pending) }
        }
    }

    /// Stops it through the workspace's own door, which is what tells the agent above it.
    ///
    /// `WorkspaceModel.closeCrewMember` rather than an archive from here: an orchestrator left
    /// waiting on a member that vanished is the failure the whole crew design is built to avoid,
    /// and the owner reaching into the sidebar is the one way a member can go without the agent
    /// above it having done anything.
    private func stop(_ pending: PendingCrewStop) async {
        // The model this launch already has, never a fresh one. Building a `WorkspaceModel` to
        // close one of its chats would start the very machinery the close is about to tear down.
        guard let model = app.existingModel(for: pending.workspaceID),
              let member = model.sessions.first(where: { $0.id == pending.sessionID })
        else { return }

        await model.closeCrewMember(member)
    }

    /// The create sheet is presented by `RootView`, so every entry point (the toolbar, the repo
    /// header's `+`, the menu bar command) goes through one notification and behaves identically:
    /// which project is meant depends on what the main window has selected, and only that window
    /// knows. See `RootView.presentCreateWorkspace`.
    private func presentCreate(in repo: Repo?) {
        renaming = nil
        NotificationCenter.default.post(name: .bloomNewWorkspace, object: repo)
    }

    /// The window is opened from `RootView` for the same reason the create window is, so every
    /// entry point posts and behaves identically.
    private func startProject() {
        NotificationCenter.default.post(name: .bloomNewProject, object: nil)
    }
}

/// The only sidebar node that observes the model's selection. The list already owns its immediate
/// highlight in `listSelection`; keeping the model echo here prevents that second write from
/// reevaluating every visible row.
private struct SidebarSelectionSync: View {
    @Environment(AppModel.self) private var app

    var selection: SidebarSelection?
    var onActivate: (SidebarSelection, SidebarSelection) -> Void
    var onFollow: (SidebarSelection) -> Void

    var body: some View {
        SidebarSelectionActivation(
            selection: selection,
            active: app.selection,
            onActivate: onActivate
        )
        .onChange(of: app.selection, initial: true) { _, target in
            onFollow(target)
        }
    }
}

extension EnvironmentValues {
    /// Whether the window's sidebar column is folded away. A sidebar's toolbar items stay in the
    /// title bar after the column has gone, beside the detail column's own toggle, so the sidebar
    /// reads this to take New and its toggle away with it.
    @Entry var isSidebarFolded = false
}

/// New and the collapse button, in one piece of glass, the way the detail column's plus, search
/// and inspector share one.
///
/// The system's own toggle cannot join a group: it is `NavigationSplitView`'s item, and a `+`
/// beside it came out as two separate capsules. So `RootView` removes that toggle and this is its
/// replacement, with the detail column's toolbar drawing one while the sidebar is folded away.
/// Folded, this draws nothing, because a sidebar's toolbar items otherwise stay in the title bar
/// after the column has gone.
struct SidebarToolbar: ToolbarContent {
    var isFolded: Bool
    var onNewWorkspace: () -> Void
    var onStartProject: () -> Void
    var onCreateWorkspace: (Repo) -> Void
    var recentProjects: [Repo]

    @Environment(\.colorScheme) private var colorScheme

    var body: some ToolbarContent {
        if !isFolded {
            // Pushes the pair to the sidebar's trailing edge. Without it they sat against the
            // traffic lights.
            ToolbarSpacer(.flexible, placement: .primaryAction)

            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    NewMenuItems(
                        recent: recentProjects,
                        onNewWorkspace: onNewWorkspace,
                        onStartProject: onStartProject,
                        onCreateWorkspace: onCreateWorkspace
                    )
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuIndicator(.hidden)
                .help("New workspace, project or conversation")
                // AppKit draws a toolbar menu's label once, so switching appearance left a white
                // `+` on a light title bar. A new identity per scheme makes it draw again.
                .id(colorScheme)

                SidebarToggleButton()
            }
        }
    }
}

/// Folds the sidebar away or brings it back, through the same notification the View menu uses.
struct SidebarToggleButton: View {
    var body: some View {
        Button("Toggle Sidebar", systemImage: "sidebar.left") {
            NotificationCenter.default.post(name: .bloomToggleSidebar, object: nil)
        }
        .help("Toggle the sidebar")
    }
}

/// A top level navigation row with an accent-coloured icon.
///
/// A view of its own rather than a `Label` built in `SidebarView`, because reading
/// `backgroundProminence` needs somewhere to read it: the value is set on the ROW, so a function
/// returning a label cannot see it and a `SidebarView` that read it would be reading the whole
/// list's.
struct SidebarNavRow: View {
    var title: String
    var icon: String
    var status: WorkspaceStatus?

    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 0) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(
                        prominence == .increased ? Palette.selectedEmphasizedText : Palette.controlAccent
                    )
            }
            if let status {
                Spacer(minLength: Metrics.spacingSmall)
                WorkspaceStatusGlyph(status: status, isOnSelection: prominence == .increased)
            }
        }
    }
}
