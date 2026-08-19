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
    @State private var selected: String?
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
        // Keyed on the revision rather than on the workspace list, which is reassigned every few
        // seconds by the diff stat refresh while this is a database read. `AppModel` bumps the
        // revision from the archive and the restore themselves, so this reloads when the answer
        // changed and at no other time.
        .task(id: app.archivedRevision) { archived = await app.archivedWorkspaces() }
        .task { await keepAgesCurrent() }
        .onChange(of: app.workspaces, initial: true) { _, _ in rebuild() }
        .onChange(of: app.repos) { _, _ in rebuild() }
        .onChange(of: archived) { _, _ in rebuild() }
        .onChange(of: app.homeFilter) { _, _ in rebuild() }
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

    /// A real `List`, so the rows come with the things a hand-built stack never gets right:
    /// AppKit's own selection fill (the accent while the list holds the keyboard, a quiet grey
    /// when it does not), arrow key navigation between rows, and row recycling, which is what
    /// keeps five hundred workspaces from being five hundred live views.
    private var list: some View {
        List(selection: $selected) {
            ForEach(listing.groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        HomeListRow(
                            row: row,
                            isRunning: app.isRunning(row.workspace),
                            now: now,
                            isSelected: selected == row.id,
                            isListFocused: isListFocused
                        )
                        .tag(row.id)
                        // Simultaneous rather than `onTapGesture`, so the list still takes the
                        // click for itself: it is what moves the keyboard into the table, and
                        // without it the arrow keys have no way of ever reaching these rows.
                        .simultaneousGesture(TapGesture().onEnded { open(row) })
                        .listRowInsets(Self.rowInsets)
                        // An archived workspace has no worktree to open, so the keyboard skips
                        // it rather than landing on a row where Return does nothing. It is still
                        // drawn, still readable and still says what it is.
                        .selectionDisabled(row.isArchived)
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
    }

    private static let rowInsets = EdgeInsets(
        top: 0, leading: HomeMetrics.rowInset, bottom: 0, trailing: HomeMetrics.rowInset
    )

    // MARK: - Summary

    /// What the readout at the end of the strip says.
    ///
    /// It describes the list rather than the database whenever the two differ. A line reading "312
    /// workspaces" above eleven rows is how a forgotten filter becomes a bug report about missing
    /// work, so a narrowed list says so in the same breath as the total it was narrowed from.
    ///
    /// Empty when there is no list. The strip is not drawn at all then, and with no project on the
    /// machine there is nothing to count in the first place.
    private var summary: String {
        guard hasAnyWorkspace else { return "" }

        // Everything on this Mac has been archived, and archived is off.
        //
        // Said as one fact rather than as a number and then a correction. `HomeListing.considered`
        // counts only what the archived switch let through, so the general shape below reports "0
        // workspaces" about a machine holding three of them, directly above a panel that says all
        // three exist. Neither half of the readout mentioned them.
        if !filter.isNarrowed, listing.considered == 0, !archived.isEmpty {
            return "\(count(archived.count, "workspace")), all archived"
        }

        var text: String
        if filter.isNarrowed {
            text = "Showing \(listing.shown) of \(count(listing.considered, "workspace"))"
        } else {
            text = count(listing.considered, "workspace")
            if app.repos.count > 1 {
                text += " across \(count(app.repos.count, "project"))"
            }
        }

        // Both ways round, for the same reason as the branch above: the count in front of this
        // clause is a count of what the archived switch let through, so a machine with archived
        // work it is not being shown has to hear about it here or nowhere.
        if listing.shownArchived > 0 {
            text += ", \(listing.shownArchived) archived"
        } else if !archived.isEmpty {
            text += ", \(archived.count) archived hidden"
        }

        let running = app.runningCount
        if running > 0 { text += ", \(running) running" }

        return text
    }

    private var hasAnyWorkspace: Bool {
        !app.workspaces.isEmpty || !archived.isEmpty
    }

    private func count(_ value: Int, _ noun: String) -> String {
        value == 1 ? "1 \(noun)" : "\(value) \(noun)s"
    }

    // MARK: - Empty

    /// Four different sentences, plus the one for a machine with no projects on it at all.
    ///
    /// One generic "nothing to show" would be wrong in every case: the fixes are to add a project,
    /// to start a workspace, to clear the search, to widen the project filter and to turn archived
    /// on, and a placeholder that names none of them leaves the user to guess which of the five
    /// controls above it did this.
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
        if app.repos.isEmpty {
            ContentUnavailableView {
                Label("No projects yet", systemImage: "folder.badge.plus")
            } description: {
                // Word for word what the sidebar's own empty state says, because on a machine with
                // no projects both are on screen at once. Two different pitches for the same
                // missing thing read as two different offers.
                Text("Point Bloom at a git repository to start running agents in it.")
            } actions: {
                Button("Choose a folder", systemImage: "folder", action: addProject)
                    .buttonStyle(.borderedProminent)
            }
        } else if !hasAnyWorkspace {
            ContentUnavailableView {
                Label("No workspaces yet", systemImage: "square.stack.3d.up")
            } description: {
                Text("A workspace gets a branch, a worktree and an agent of its own.")
            } actions: {
                Button("New workspace", systemImage: "plus") { requestWorkspace(in: nil) }
                    .buttonStyle(.borderedProminent)
            }
        } else if listing.isEmpty {
            if !filter.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView {
                    Label("No workspace matches", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing here is called, branched or filed under \"\(filter.query)\".")
                } actions: {
                    Button("Clear the search") { app.homeFilter.query = "" }
                }
            } else if !filter.projects.isEmpty {
                ContentUnavailableView {
                    Label("Nothing in \(projectPhrase)", systemImage: "folder")
                } description: {
                    Text("The other projects still have work in them.")
                } actions: {
                    Button("Show all projects") { app.homeFilter.projects = [] }
                }
            } else {
                ContentUnavailableView {
                    Label("Everything here is archived", systemImage: "archivebox")
                } description: {
                    Text("All \(count(archived.count, "workspace")) on this Mac have been archived.")
                } actions: {
                    Button("Show archived") { app.homeFilter.showsArchived = true }
                }
            }
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
    private func rebuild() {
        let stamp = Date()
        now = stamp
        listing = HomeList.build(
            repos: app.repos,
            workspaces: app.workspaces,
            archived: archived,
            filter: filter,
            now: stamp
        )
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

    private func row(for id: String) -> HomeRow? {
        for group in listing.groups {
            if let match = group.rows.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    // MARK: - Actions

    private func open(_ row: HomeRow) {
        // An archived workspace has no worktree left to open, so the row is a record rather than
        // a destination. Selecting it would put the detail column on a workspace `AppModel` does
        // not hold and leave the window on a blank pane.
        guard !row.isArchived else { return }
        app.selection = .workspace(row.id)
    }

    /// Handed to `RootView`, which owns the only create sheet in the app.
    private func requestWorkspace(in repo: Repo?) {
        NotificationCenter.default.post(name: .bloomNewWorkspace, object: repo)
    }

    private func addProject() {
        Task { await app.addProjectByAsking() }
    }
}
