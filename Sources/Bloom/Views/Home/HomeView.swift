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
    /// The row under the pointer, held here rather than in each row, so crossing the pane lights
    /// one row at a time and a hover invalidates the list rather than nothing at all.
    @State private var hovered: WorkspaceID?
    /// The id of the row being renamed in place, shared across the whole list so only one field
    /// can ever be open. The same arrangement the sidebar's rows use.
    @State private var renaming: WorkspaceID?

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
            // Only once there is something for the controls to act on. A search field, a project
            // filter and an archived switch over an empty machine are three controls that cannot
            // change what is on screen, sitting directly above a panel explaining that there is
            // nothing on screen. With them gone the pane is entirely empty, which is the one
            // arrangement macOS does centre a message in.
            if hasAnyWorkspace {
                HomeBar(
                    summary: summary,
                    repos: app.repos,
                    archivedCount: archived.count,
                    filter: $app.homeFilter
                )
            }

            content
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
        .task(id: app.archivedRevision) { archived = await app.archivedWorkspaces() }
        .task { await keepAgesCurrent() }
        .onChange(of: app.workspaces, initial: true) { _, _ in rebuild() }
        .onChange(of: app.repos) { _, _ in rebuild() }
        .onChange(of: archived) { _, _ in rebuild() }
        // Rescoped, so a filter widening is not the whole list fading in at once. Home's search,
        // its project menu and Hide archived are one control's worth of the same decision, and
        // they answer the same way the sidebar's filter does. See `RowArrival`.
        .onChange(of: app.homeFilter) { _, _ in rebuild(rescoped: true) }
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
    /// key navigation between rows, section headers that stick, and row recycling, which is what
    /// keeps five hundred workspaces from being five hundred live views.
    ///
    /// The one thing it is NOT allowed to bring is its own selection fill. Under `.listStyle(.inset)`
    /// that is a full bleed bar of the system accent, which was a third selection treatment in a
    /// window that already has one. `HomeRowBackground` is painted over it.
    private var list: some View {
        List(selection: $selected) {
            ForEach(listing.groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        HomeListRow(
                            row: row,
                            isRunning: app.isRunning(row.workspace),
                            isAwaitingPermission: app.isAwaitingPermission(row.workspace),
                            now: now,
                            isRenaming: renaming == row.id,
                            onCommitRename: { commitRename(row, to: $0) },
                            onCancelRename: { renaming = nil }
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
                            HomeRowMenu(row: row) { renaming = $0 }
                        }
                    }
                } header: {
                    HomeGroupHeading(title: group.title, count: group.rows.count)
                        // The rows' own leading inset, said as padding because a section header
                        // ignores `listRowInsets` under the inset style. Without it the heading
                        // hangs a spacing step to the left of the column it heads, which is the
                        // one misalignment on this screen the eye actually catches.
                        .padding(.leading, Self.rowInsets.leading)
                }
            }
        }
        .listStyle(.inset)
        .settlesArrivals($arrival)
        .scrollContentBackground(.hidden)
        .focused($isListFocused)
        .task {
            // A beat, so the table exists before the focus is aimed at it.
            try? await Task.sleep(for: .milliseconds(50))
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
        // list answered with nothing at all. Live rows only: an archived row's worktree has
        // already gone, and destroying its record is the Archive screen's own gesture, behind a
        // confirmation, because there is no undo for that one.
        .onDeleteCommand {
            guard let selected, let row = row(for: selected), !row.isArchived else { return }
            Task { await app.archive(row.workspace) }
        }
    }

    private static let rowInsets = EdgeInsets(
        top: 0, leading: HomeMetrics.rowInset, bottom: 0, trailing: HomeMetrics.rowInset
    )

    // MARK: - Summary

    /// What the readout at the end of the strip says. `HomeList.summary` in the core, where its
    /// five branches can be asked about: this was four pieces of view state picking between
    /// sentences, and one of those sentences had already been wrong once.
    private var summary: String {
        HomeList.summary(
            listing: listing,
            isNarrowed: filter.isNarrowed,
            projects: app.repos.count,
            running: app.runningCount
        )
    }

    private var hasAnyWorkspace: Bool {
        !app.workspaces.isEmpty || !archived.isEmpty
    }

    // MARK: - Empty

    /// Five states, drawn. Which one a machine is in, and every word of it, is `HomeEmptyState`
    /// in the core: the order of those tests is load bearing and was a five-branch `if` chain in
    /// here, tangled up with the views it produced, where nothing could ask it anything.
    ///
    /// **Why these are still centred, when the rest of Home moved to the leading edge.** macOS
    /// centres a message in a pane that is empty, and only in a pane that is empty: an empty Finder
    /// window, an unselected Mail message, a closed Xcode editor. What it never does is float a
    /// centred block of marketing in the middle of a pane whose chrome is left aligned above it,
    /// which is what this screen was doing, and the fix for that was the chrome rather than the
    /// centring. Two of these five appear with no strip above them at all, so the pane really is
    /// empty; the other three appear under a strip of controls that is the reason the list is
    /// empty, which is the same arrangement as a Mail search that matches nothing.
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
            hasProjectFilter: !filter.projects.isEmpty,
            projectPhrase: projectPhrase,
            archivedCount: archived.count
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

    /// The way out of each state, which is the reason there are five states rather than one.
    ///
    /// The two that are prominent are the two that add something. Clearing a search, widening a
    /// filter and unhiding archived are all undoing a control that is still on screen directly
    /// above, so a filled button for them would be shouting about a switch the reader can see.
    @ViewBuilder
    private func action(for state: HomeEmptyState) -> some View {
        switch state {
        case .noProjects:
            Button(state.actionTitle, systemImage: "folder", action: addProject)
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
        case .allArchived:
            Button(state.actionTitle) { app.homeFilter.hidesArchived = false }
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
            filter: filter,
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

    /// Handed to `RootView`, which owns the only create sheet in the app.
    private func requestWorkspace(in repo: Repo?) {
        NotificationCenter.default.post(name: .bloomNewWorkspace, object: repo)
    }

    private func addProject() {
        Task { await app.addProjectByAsking() }
    }

    private func commitRename(_ row: HomeRow, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != row.workspace.name else { return }
        Task { await app.rename(row.workspace, to: name) }
    }
}
