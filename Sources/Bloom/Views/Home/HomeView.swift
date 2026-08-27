import SwiftUI
import BloomCore

/// The centre pane when nothing is selected: every workspace on this Mac, newest first.
///
/// **Why a flat list and not the grid of project blocks this replaced.** Grouping Home by project
/// duplicated the sidebar, which is two hundred points to the left, always on screen, and already
/// the definitive answer to "what projects do I have". Home was therefore a second, worse copy of
/// it: capped at six cards a project, so its totals and its contents disagreed, and silent about
/// the one question a person running a dozen agents in parallel actually opens this window with,
/// which is what has been happening. Grouping by time answers that instead. Each heading carries
/// its own count, so "yesterday, 48" is readable before a single row is.
///
/// **The Archived chip is also where storage lives, and it used to be a pane in Settings.** That
/// pane listed every archived workspace with its project, its branch, its age and its size, over a
/// list this screen was already drawing with the project, the branch and the age on it: the same
/// objects twice, with one extra column and a different sort. What crossed over is the column, an
/// order to put it in, and the two totals, which are in the status bar because that is where facts
/// about the whole of the list already live. What did not cross is written down where it was
/// dropped: the share bar and the counts in `ArchivedWorkspaceFootprint.contents`, the
/// multi-selection in `ArchiveCleanup`.
///
/// **What is computed where.** The filtering, the recency sort and the date buckets are a pass
/// over every workspace on the machine, so they live in `HomeList` and run when their inputs
/// change, never inside a `body`. What each row cannot cache is its own state: whether an agent
/// has a turn open right now, and what GitHub last said about the branch. Those move without the
/// workspace list moving, they change no row's position, and they are pure function calls with no
/// subprocess behind them, so each row resolves its own. Nothing here starts a git or a `gh`
/// process: the pull request cache is read and never filled, because forty rows filling it would
/// be forty subprocesses for a screen the user has not clicked into.
struct HomeView: View {
    @Environment(AppModel.self) private var app

    /// Archived workspaces, which `AppModel` deliberately does not hold: it lists active ones so
    /// the sidebar cannot show a worktree that no longer exists. Home is the one screen that has
    /// to be able to look at them, so it asks `AppModel` for them, once, rather than per row.
    @State private var archived: [Workspace] = []
    @State private var listing = HomeListing.empty
    /// The list's own selection, not the app's. Writing to `app.selection` would navigate away
    /// from Home, so arrowing down the list would open every workspace it passed.
    @State private var selected: WorkspaceID?
    /// The instant every age and every date heading on screen was worked out against. Held rather
    /// than read per row, so a list of forty rows cannot show forty slightly different nows, and
    /// so "3 days ago" becomes "4 days ago" for the whole list at once.
    @State private var now = Date()
    /// Whether the list has the keyboard.
    ///
    /// Taken on arrival rather than left to the user to find. Full Keyboard Access is off by
    /// default on macOS, so Tab reaches the search field and the buttons and never the table:
    /// without this, the only way into the list is to click a row, and clicking a row opens it.
    /// A list you cannot arrow down is not a list.
    @FocusState private var isListFocused: Bool
    /// Whether the list has already been handed the keyboard on this visit to Home.
    ///
    /// Held out here rather than beside the `.task` that reads it, because that task belongs to
    /// the table and the table is not what a visit to Home is: the pane draws either the empty
    /// state or the list, so a search whose results arrive after its names have stopped matching
    /// destroys the table and builds another one. This state sits above that swap and is reset
    /// only when `HomeView` itself is rebuilt, which is when the selection leaves Home and comes
    /// back. See `HomeListKeyboard`.
    @State private var hasClaimedKeyboard = false
    /// The row under the pointer, held here rather than in each row, so crossing the pane lights
    /// one row at a time and a hover invalidates the list rather than nothing at all.
    @State private var hovered: WorkspaceID?
    /// The id of the row being renamed in place, shared across the whole list so only one field
    /// can ever be open. The same arrangement the sidebar's rows use.
    @State private var renaming: WorkspaceID?
    /// The deletion waiting to be confirmed, held by the list rather than by the menu, because a
    /// menu is gone by the time the sheet would appear.
    @State private var deleting: ArchiveDeletion?

    /// What each archived record still holds, measured, and only while the Archived chip is lit.
    /// See `loadFootprints` for why it is not simply always loaded.
    @State private var footprints = ArchiveCleanup(footprints: [])
    /// How big the database file is, loaded beside the footprints and reported by the status bar.
    @State private var databaseSize: DatabaseSize?
    /// Which `archivedRevision` the two above were measured at, so flicking between All and
    /// Archived does not re-run a database read and a `git for-each-ref` per project for an
    /// answer that cannot have changed.
    @State private var measuredRevision: Int?
    /// Whether a `VACUUM` is running. It is seconds of the store actor answering nothing, so the
    /// button says so rather than looking like it did not take the click.
    @State private var isCompacting = false

    /// Which rows have just been added to the list, so they can fade in rather than appear. The
    /// same tracker and the same rules as the sidebar's, which is what stops one workspace
    /// arriving two different ways in two lists on the same screen.
    ///
    /// Reset with the view, which is exactly what is wanted. `HomeView` is rebuilt every time the
    /// selection leaves Home and comes back, and `RowArrival` says nothing arrives into a list it
    /// has never seen anything in, so coming back to Home lands its forty rows in silence.
    @State private var arrival = RowArrival<WorkspaceID>()

    /// Held by `AppModel` rather than by this view, which is thrown away and rebuilt every time
    /// the selection leaves Home and comes back. A filter in `@State` would be cleared by opening
    /// any workspace at all.
    private var filter: HomeFilter { app.homeFilter }

    var body: some View {
        @Bindable var app = app

        return VStack(spacing: 0) {
            // Only once there is something for the controls to act on. A row of chips and a
            // project menu over an empty machine are controls that cannot change what is on
            // screen, sitting directly above a panel explaining that there is nothing on screen.
            // With them gone the pane is entirely empty, which is the one arrangement macOS does
            // centre a message in.
            if hasAnyWorkspace {
                HomeBar(
                    repos: app.repos,
                    counts: listing.counts,
                    isSearching: listing.isSearching,
                    filter: $app.homeFilter
                )
            }

            content

            // The counts, at the foot of the pane rather than at the trailing end of the strip,
            // beside the rows they are about. See `HomeStatusBar`.
            if hasAnyWorkspace, !summary.isEmpty {
                HomeStatusBar(summary: summary, compaction: compaction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.windowBackground)
        // What the Workspace menu acts on while this screen is up. Home's selection is its own,
        // not the app's, so before this the menu bar had no way of hearing about a row that was
        // visibly highlighted: Archive, Reveal in Finder, Open in Editor and Copy Branch Name all
        // greyed out on the screen that lists every workspace on the Mac. On the whole pane rather
        // than on the list, so the row still answers while the keyboard is in the search field, as
        // it does in Mail. See `FocusedMenuValues`.
        .focusedValue(\.focusedWorkspaceRow, focusedRow)
        // Rename from the menu bar. Ignored for a workspace this list is not drawing, so the
        // sidebar and Home can both listen to one post.
        .onReceive(NotificationCenter.default.publisher(for: .bloomRenameWorkspace)) { note in
            guard let raw = note.userInfo?[Notification.bloomWorkspaceIDKey] as? String,
                  let row = row(for: WorkspaceID(raw)), !row.isArchived else { return }
            renaming = row.id
        }
        // Keyed on the revision rather than on the workspace list, which is reassigned every few
        // seconds by the diff stat refresh while this is a database read. `AppModel` bumps the
        // revision from the archive and the restore themselves, so this reloads when the answer
        // changed and at no other time.
        .task(id: app.archivedRevision) {
            archived = await app.archivedWorkspaces()
            await loadFootprints()
        }
        .task { await keepAgesCurrent() }
        // The one irreversible act in the app, so it counts what would go rather than asking "are
        // you sure" over an unnamed quantity.
        .confirmation($deleting) { deletion in
            Confirmation(
                title: deletion.title,
                message: deletion.message,
                confirmLabel: deletion.confirmLabel,
                cancelLabel: deletion.cancelLabel,
                tone: .destructive
            )
        } onConfirm: { deletion in
            Task { await delete(deletion) }
        }
        .onChange(of: app.workspaces, initial: true) { _, _ in rebuild() }
        .onChange(of: app.repos) { _, _ in rebuild() }
        .onChange(of: archived) { _, _ in rebuild() }
        // The two halves of the running state, watched separately because they move separately:
        // a turn starting and a turn stopping to ask are different moments, and both change what
        // the "Needs you" and "Running" chips count.
        .onChange(of: app.runningWorkspaceIDs) { _, _ in rebuild() }
        .onChange(of: app.waitingWorkspaceIDs) { _, _ in rebuild() }
        // Rescoped, so a filter widening is not the whole list fading in at once. The search, the
        // chips and the project menu are one control's worth of the same decision, and they answer
        // the same way the sidebar's filter does. See `RowArrival`.
        .onChange(of: app.homeFilter) { old, new in
            rebuild(rescoped: true)
            // The Archived chip is the only one that draws sizes, so it is the only one that pays
            // for measuring them. See `loadFootprints`.
            if old.scope != new.scope { Task { await loadFootprints() } }
            // Only when the QUERY moved. Clicking a chip or a project rebuilds the list out of
            // results already in memory, and re-running an FTS5 match and a join for it would put
            // a database query behind a filter that changes nothing about what matched.
            //
            // The index is asked from here rather than from wherever the field lives, because
            // this is what knows the answer is on screen. It debounces, and it clears itself when
            // there is nothing to ask. See `AppModel+TranscriptSearch`.
            if old.query != new.query { app.searchTranscripts(new.query) }
        }
        .onChange(of: app.transcriptResults) { _, _ in rebuild(rescoped: true) }
        .onAppear { app.searchTranscripts(app.homeFilter.query) }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if let empty = emptyState {
            empty
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    /// A real `List`, so the rows come with the things a hand-built stack never gets right: arrow
    /// key navigation between rows and row recycling, which is what keeps five hundred workspaces
    /// from being five hundred live views.
    ///
    /// The date headings are ordinary rows rather than `Section` headers. As headers they pinned
    /// to the top and the rows slid underneath them, which reads as an index keeping your place in
    /// a long document; this is a flat list of workspaces and there is no place to keep.
    ///
    /// The one thing it is NOT allowed to bring is its own selection fill. Under `.listStyle(.inset)`
    /// that is a full bleed bar of the system accent, which was a third selection treatment in a
    /// window that already has one. `HomeRowBackground` is painted over it.
    private var list: some View {
        List(selection: $selected) {
            ForEach(listing.groups) { group in
                Section {
                    HomeGroupHeading(title: group.title)
                        .listRowInsets(Self.rowInsets)
                        .listRowBackground(Color.clear)
                        .selectionDisabled()

                    ForEach(group.rows) { row in
                        HomeListRow(
                            row: row,
                            isRunning: app.isRunning(row.workspace),
                            isAwaitingPermission: app.isAwaitingPermission(row.workspace),
                            now: now,
                            isRenaming: renaming == row.id,
                            onCommitRename: { commitRename(row, to: $0) },
                            onCancelRename: { closeField(of: row) }
                        )
                        // Innermost, on the drawing alone. Everything below this line is what the
                        // list is told about the row, and a row that is fading in is still
                        // selectable, clickable and right clickable throughout.
                        .arrivingRow(arrival.isArriving(row.id))
                        .tag(row.id)
                        // Simultaneous rather than `onTapGesture`, so the list still takes the
                        // click for itself: it is what moves the keyboard into the table, and
                        // without it the arrow keys have no way of ever reaching these rows.
                        .simultaneousGesture(TapGesture().onEnded { open(row) })
                        .listRowInsets(Self.rowInsets)
                        // Home's rows answered to the pointer with nothing at all: no tint under
                        // it, and no menu on a right click, while the identical row in the sidebar
                        // two hundred points to the left had both. See `HomeRowBackground` for why
                        // the fill is drawn here rather than left to the list.
                        .onHoverChange { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
                        .listRowBackground(
                            HomeRowBackground(
                                isSelected: selected == row.id,
                                isHovered: hovered == row.id
                            )
                        )
                        .contextMenu {
                            HomeRowMenu(row: row, onRename: { renaming = $0 }, onDelete: askToDelete)
                        }
                    }
                }
            }

            transcriptResults
        }
        .listStyle(.inset)
        .settlesArrivals($arrival)
        .scrollContentBackground(.hidden)
        .focused($isListFocused)
        .task {
            // A beat, so the table exists before the focus is aimed at it.
            try? await Task.sleep(for: .milliseconds(50))
            // And then only if there is still nobody the keyboard would be taken from. This task
            // runs whenever the TABLE is built, which a search does twice per character, so
            // without the guard typing "df" ended with the caret in the results. See
            // `HomeListKeyboard`, which carries the whole sequence.
            guard HomeListKeyboard.claims(
                searchFieldHasKeyboard: app.isSearchFieldFocused, hasClaimed: hasClaimedKeyboard
            ) else { return }
            hasClaimedKeyboard = true
            isListFocused = true
        }
        // Return opens whatever the arrow keys landed on. The list has the keyboard whenever the
        // arrow keys are doing anything, so this is where the key press arrives.
        .onKeyPress(.return) {
            guard let selected, let row = row(for: selected) else { return .ignored }
            open(row)
            return .handled
        }
        // Delete on the highlighted row, which is what Mail does with the same key and what this
        // list answered with nothing at all.
        //
        // **It means two different things on the two kinds of row, and that is the state each row
        // is in rather than an overload.** A live workspace has a worktree, and the way to be done
        // with it is to archive it, which is reversible and which `archive` asks about when there
        // is anything to lose. An archived one has already been through that; the only thing left
        // to destroy is the record, and there is no undo for it, so the key raises the same
        // confirmation the row's own menu does and destroys nothing on its own. That second half
        // used to be Settings > Storage's gesture, in another window, which is the pane this list
        // has absorbed.
        .onDeleteCommand {
            guard let selected, let row = row(for: selected) else { return }
            if row.isArchived {
                askToDelete(row.workspace)
            } else {
                Task { await app.archive(row.workspace) }
            }
        }
    }

    /// The second kind of result: workspaces whose transcript matched, with the best few lines
    /// under each.
    ///
    /// **This is what merging the Search screen into Home actually added.** Home's field never
    /// touched the full text index; that half only ever existed on the screen that has now gone,
    /// so it is carried across rather than deleted with the screen around it.
    ///
    /// In the same `List` as the workspace rows rather than beside it, which is the whole reason
    /// searching does not change the shape of this pane. The rows above keep AppKit's arrow keys
    /// and Return, and there is no second keyboard model to write: the Search screen forwarded
    /// both by hand out of an `NSTextField`, and that goes with it.
    ///
    /// Selection is refused on these, deliberately. A transcript result is a workspace with
    /// several lines nested inside it, so Return would have two meanings and neither is answered
    /// by walking a flat list. They are reached with the pointer, exactly as they were before.
    @ViewBuilder
    private var transcriptResults: some View {
        if !listing.transcripts.isEmpty {
            Section {
                ForEach(listing.transcripts) { result in
                    TranscriptResultRow(
                        result: result,
                        workspace: workspace(result.workspaceID),
                        repo: workspace(result.workspaceID).flatMap { app.repo(for: $0) },
                        isArchived: archived.contains { $0.id == result.workspaceID },
                        openWorkspace: { openTranscript(result) },
                        openMatch: { match in Task { await app.open(match) } }
                    )
                    .listRowInsets(Self.rowInsets)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
                }
            } header: {
                Text(HomeList.transcriptHeading(listing.transcripts))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.leading, Self.rowInsets.leading)
            }
        }

        if listing.isSearching, app.isTranscriptIndexIncomplete {
            // Said out loud rather than hidden, because a search of a half built index is a search
            // that can be wrong, and a wrong "nothing matched" about work the user knows they did
            // is the one answer this pane must never give silently.
            Label("Still indexing older transcripts", systemImage: "clock")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .listRowInsets(Self.rowInsets)
                .listRowBackground(Color.clear)
                .selectionDisabled()
        }
    }

    private static let rowInsets = EdgeInsets(
        top: 0, leading: HomeMetrics.rowInset, bottom: 0, trailing: HomeMetrics.rowInset
    )

    // MARK: - Summary

    /// What the status bar at the foot of the pane says. `HomeList.summary` in the core, where its
    /// branches can be asked about: this was four pieces of view state picking between sentences,
    /// and one of those sentences had already been wrong once.
    private var summary: String {
        HomeList.summary(
            listing: listing,
            filter: filter,
            projects: app.repos.count,
            database: databaseSize
        )
    }

    /// The compaction offer, which is nil almost always: it needs the Archived chip lit, a
    /// measurement taken, and enough unused space in the file for the wait to be worth it.
    private var compaction: HomeStatusBar.Compaction? {
        guard filter.scope.showsFootprints, let size = databaseSize, size.isWorthCompacting else {
            return nil
        }
        return HomeStatusBar.Compaction(help: size.compactionHelp, isRunning: isCompacting) {
            Task { await compact() }
        }
    }

    private var hasAnyWorkspace: Bool {
        !app.workspaces.isEmpty || !archived.isEmpty
    }

    // MARK: - Empty

    /// The empty states, drawn. Which one a machine is in, and every word of it, is
    /// `HomeEmptyState` in the core: the order of those tests is load bearing and was a
    /// five-branch `if` chain in here, tangled up with the views it produced, where nothing could
    /// ask it anything.
    ///
    /// **Why these are still centred, when the rest of Home moved to the leading edge.** macOS
    /// centres a message in a pane that is empty, and only in a pane that is empty: an empty Finder
    /// window, an unselected Mail message, a closed Xcode editor. What it never does is float a
    /// centred block of marketing in the middle of a pane whose chrome is left aligned above it,
    /// which is what this screen was doing, and the fix for that was the chrome rather than the
    /// centring. Two of these appear with no strip above them at all, so the pane really is empty;
    /// the rest appear under a strip of controls that is the reason the list is empty, which is
    /// the same arrangement as a Mail search that matches nothing.
    ///
    /// The prose is one sentence each. It was two, and the second one was always a description of
    /// the product rather than of the state, which is what an empty pane on a Mac does not do.
    /// Each still carries a real button, at the system's own control size: `.controlSize(.large)`
    /// is an iOS proportion, and next to a 22 point search field it was a slab.
    @ViewBuilder
    private var emptyState: (some View)? {
        if let state = HomeEmptyState.resolve(
            hasProjects: !app.repos.isEmpty,
            hasAnyWorkspace: hasAnyWorkspace,
            isListEmpty: listing.isEmpty,
            query: filter.query,
            scope: filter.scope,
            hasProjectFilter: !filter.projects.isEmpty,
            projectPhrase: projectPhrase
        ) {
            ContentUnavailableView {
                Label(state.title, systemImage: state.symbol)
            } description: {
                Text(state.message)
            } actions: {
                action(for: state)
            }
        }
    }

    /// The way out of each state, which is the reason there are several states rather than one.
    ///
    /// The two that are prominent are the two that add something. Clearing a search, widening a
    /// filter and going back to All are all undoing a control that is still on screen directly
    /// above, so a filled button for them would be shouting about a chip the reader can see.
    @ViewBuilder
    private func action(for state: HomeEmptyState) -> some View {
        switch state {
        case .noProjects:
            // One button, where this state used to be the only one with two. The second went to a
            // file panel, and pointing at a folder is what the sheet's own Choose does now.
            Button(state.actionTitle, systemImage: "plus", action: startProject)
                .buttonStyle(.borderedProminent)
                // Tinted explicitly, like every other prominent button in the app: untinted it
                // follows the system accent, which on a Mac set to Graphite is grey glass. See
                // `EmptyStateView`, which says the same over the same button.
                .tint(Palette.accentFill)
        case .noWorkspaces:
            Button(state.actionTitle, systemImage: "plus") { requestWorkspace(in: nil) }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accentFill)
        case .noMatch:
            Button(state.actionTitle) { app.homeFilter.query = "" }
        case .noneInChosenProjects:
            Button(state.actionTitle) { app.homeFilter.projects = [] }
        case .emptyScope:
            Button(state.actionTitle) { app.homeFilter.scope = .all }
        }
    }

    private var projectPhrase: String {
        filter.projects.count == 1
            ? (app.repos.first { filter.projects.contains($0.id) }?.name ?? "that project")
            : "\(filter.projects.count) projects"
    }

    // MARK: - Deriving

    /// One pass over every workspace on the machine, run when its inputs change rather than while
    /// drawing. `now` is stamped here so the buckets the rows are filed under and the ages the
    /// rows print can never disagree.
    /// - Parameter rescoped: whether the list is being rebuilt because a filter moved, in which
    ///   case nothing in it counts as having arrived.
    private func rebuild(rescoped: Bool = false) {
        let stamp = Date()
        now = stamp
        listing = HomeList.build(
            repos: app.repos,
            workspaces: app.workspaces,
            archived: archived,
            transcripts: app.transcriptResults,
            filter: filter,
            activity: HomeActivity(
                running: app.runningWorkspaceIDs, waiting: app.waitingWorkspaceIDs
            ),
            footprints: footprints,
            now: stamp
        )
        // Every row in the list, flattened out of its date heading. Which heading a row is filed
        // under is not identity: a row crosses from Today to Yesterday at midnight and again
        // whenever `now` is re-stamped, and taking the groups one at a time would read that as a
        // row leaving one list and arriving in another. The one pass a minute this function makes
        // to keep the ages honest would then fade something every night.
        //
        // In the same breath as `listing` rather than from an `onChange` watching it, so a row
        // and the fact that it is new land in one update and the row's first drawn frame is the
        // faded one.
        let ids = listing.groups.flatMap { $0.rows.map(\.id) }
        if rescoped {
            arrival.adopt(ids)
        } else {
            arrival.absorb(ids)
        }
    }

    /// Measures what the archived records hold, and how big the file holding them is.
    ///
    /// **Only while the Archived chip is lit, and only once per change to the archive.** Both
    /// halves matter. `archiveCleanup` is six aggregate queries over the whole database plus one
    /// `git for-each-ref` per project, and Home is the screen the app opens with: paying that at
    /// launch, in every window, to fill a column that two of the chips do not draw is the kind of
    /// cost that never shows up in a profile and is always there. And `archivedRevision` moves
    /// only when something is archived, restored or deleted, so somebody flicking between All and
    /// Archived measures the database once rather than once a click.
    ///
    /// The revision is read before the awaits and stored after them. If the archive changed while
    /// this was running, what is stored is the revision this answer is actually about, so the
    /// guard fails next time and the measurement is taken again.
    private func loadFootprints() async {
        guard filter.scope.showsFootprints else { return }
        let revision = app.archivedRevision
        guard measuredRevision != revision else { return }
        footprints = await app.archiveCleanup()
        databaseSize = await app.databaseSize()
        measuredRevision = revision
        rebuild()
    }

    /// Keeps "3h" from sitting at "3h" all afternoon.
    ///
    /// A minute is far finer than any age on screen needs, and it is deliberately not a second:
    /// the pass it triggers walks every workspace on the machine, and nothing in this list is
    /// measured finely enough for a per-second clock to change a single character of it.
    private func keepAgesCurrent() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            rebuild()
        }
    }

    /// Every group is walked, because the arrow keys walk the whole list: a row the selection can
    /// land on and this cannot find leaves Return doing nothing and greys out every item in the
    /// Workspace menu.
    private func row(for id: WorkspaceID) -> HomeRow? {
        for group in listing.groups {
            if let match = group.rows.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    /// The highlighted row, offered to the menu bar. It carries the workspace itself because an
    /// archived one is nowhere else in memory: `AppModel` holds live workspaces alone, and this
    /// screen is the only one that lists both. See `FocusedMenuValues`.
    private var focusedRow: FocusedWorkspaceRow? {
        guard let selected, let row = row(for: selected) else { return nil }
        return FocusedWorkspaceRow(workspace: row.workspace, isArchived: row.isArchived)
    }

    // MARK: - Actions

    /// Raises the confirmation for one archived workspace.
    ///
    /// Through `archiveCleanup`, which loads every archived footprint, rather than a query for
    /// this one. That is a database read and a `for-each-ref` per project to delete one row, and
    /// it is deliberate: the footprint is what the confirmation counts (the chats, the transcript
    /// rows, the review comments somebody typed by hand), and the branch standing is what stops it
    /// claiming the work is gone when the branch is still there. Both are already written and
    /// tested there, and a second cheaper path would be a second set of numbers to keep true.
    ///
    /// It measures again even when the Archived chip has already measured, and that is not waste.
    /// What this needs is the branch standing at the moment the question is put, and a branch can
    /// be deleted in a terminal between the chip being pressed and the menu being opened.
    private func askToDelete(_ workspace: Workspace) {
        Task {
            let cleanup = await app.archiveCleanup()
            guard let footprint = cleanup.footprints.first(where: { $0.id == workspace.id }) else {
                return
            }
            deleting = ArchiveDeletion([footprint])
        }
    }

    /// Destroys the records, and says so when the database refuses.
    ///
    /// **A refusal used to be swallowed here**: the outcome was discarded, the rows reloaded, and
    /// every one of them was still there with nothing said. The pane that did report it was
    /// Settings > Storage, which raised the sentence itself because it stood in the Settings
    /// window and `app.alert` is presented in the main one. This list is in the main window, so
    /// it hands the sentence to the one presenter rather than growing an alert of its own.
    ///
    /// A delete that worked says nothing, which is `ArchiveDeletionOutcome.sentence`'s rule: the
    /// rows leaving the list is the whole report.
    private func delete(_ deletion: ArchiveDeletion) async {
        let outcome = await app.deleteArchived(deletion.footprints.map(\.id))
        if let sentence = outcome.sentence {
            app.alert = BloomAlert(title: "Nothing was deleted", message: sentence)
        }
    }

    /// Hands the pages a delete freed back to the filesystem. Slow, never automatic, and offered
    /// only where the number it changes is printed. See `Store.compactDatabase`.
    private func compact() async {
        isCompacting = true
        await app.compactDatabase()
        databaseSize = await app.databaseSize()
        isCompacting = false
    }

    /// An archived row opens too, into the reader rather than into the centre column.
    ///
    /// It used to open into nothing at all: the row was `selectionDisabled`, a click returned
    /// early and a double click and a right click did no more, so an archived workspace listed by
    /// "Showing archived" was a line of text with no way into it. See `ArchivedWorkspaceView`.
    private func open(_ row: HomeRow) {
        if row.isArchived {
            app.openArchived(row.workspace)
        } else {
            app.selection = .workspace(row.id)
        }
    }

    /// The workspace a transcript result names, live or archived. `AppModel` holds only the live
    /// ones, and this pane is the one place that has both lists to hand.
    private func workspace(_ id: WorkspaceID) -> Workspace? {
        app.workspaces.first { $0.id == id } ?? archived.first { $0.id == id }
    }

    /// The whole workspace, from the header of a transcript result. Same split as a name hit: a
    /// live one opens the centre column, an archived one opens the reader.
    private func openTranscript(_ result: TranscriptWorkspaceMatches) {
        guard let workspace = workspace(result.workspaceID) else { return }
        if workspace.state == .active {
            app.selection = .workspace(workspace.id)
        } else {
            app.openArchived(workspace)
        }
    }

    /// Handed to `RootView`, which is what opens the create window. See `openCreateWindow`.
    private func requestWorkspace(in repo: Repo?) {
        NotificationCenter.default.post(name: .bloomNewWorkspace, object: repo)
    }

    /// Handed to `RootView`, which owns the only sheet that starts a project.
    private func startProject() {
        NotificationCenter.default.post(name: .bloomNewProject, object: nil)
    }

    /// The name has already been through `InPlaceRename` in the row, which is what decided there
    /// was anything to write at all: it is trimmed, not empty, and different from the one the
    /// workspace has. All that is left here is closing the field and writing it.
    private func commitRename(_ row: HomeRow, to newName: String) {
        closeField(of: row)
        Task { await app.rename(row.workspace, to: newName) }
    }

    /// Only if the open field is still this row's. A rename started on another row is what ends
    /// this one, and clearing the shared id unconditionally would close the field that had just
    /// been opened over there.
    private func closeField(of row: HomeRow) {
        if renaming == row.id { renaming = nil }
    }
}
