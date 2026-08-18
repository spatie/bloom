import SwiftUI
import AppKit
import BloomCore

/// One project and its workspaces, as a collapsible section of the source list.
///
/// The section owns the interaction that surrounds a row (context menus, drag to reorder, the
/// archive confirmation) while `WorkspaceRow` stays a pure drawing of a workspace. Splitting it
/// this way keeps the row cheap to redraw, which matters because a running agent updates its diff
/// stat every few seconds.
///
/// The rows are handed in already filtered and sorted (see `SidebarRepoGroup`), so nothing here
/// walks the workspace list.
///
/// Collapsing is bound to the repo's stored `collapsed` flag through `Section(isExpanded:)`, but
/// the control that drives it is the header's own leading mark. See `disclosure` for why: the
/// list draws no triangle of its own here, so before this the flag had no affordance at all.
struct RepoSection: View {
    var repo: Repo
    var rows: [Workspace]
    /// Only used to say why the section is empty, which is a different sentence when a filter is
    /// hiding rows than when the project has none.
    var isFiltered: Bool
    @Binding var renaming: String?
    /// Raised to the sidebar, which owns the create sheet.
    var onCreateWorkspace: (Repo) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isRenamingRepo = false
    @State private var repoDraft = ""
    @FocusState private var repoFieldFocused: Bool

    @State private var isConfirmingRemove = false
    /// Lights the `+`. It belongs to this header rather than to a hover id shared across the whole
    /// list, so crossing the pane lights one project at a time.
    @State private var isHeaderHovered = false

    var body: some View {
        Section(isExpanded: isExpanded) {
            ForEach(rows) { workspace in
                row(workspace)
            }
            if rows.isEmpty {
                Text(isFiltered ? "Nothing matches the filter" : "No workspaces yet")
                    .font(Typo.caption)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            header
        }
    }

    /// The stored flag is the source of truth, so the binding only writes when the list is asking
    /// for the state it is not already in. Anything else would toggle back on every redraw.
    private var isExpanded: Binding<Bool> {
        Binding(
            get: { !repo.collapsed },
            set: { expanded in
                guard expanded == repo.collapsed else { return }
                Task { await app.toggleCollapsed(repo) }
            }
        )
    }

    // MARK: - Header

    /// The confirmations hang off the header rather than off the `Section`, because a section is
    /// a layout instruction to the list rather than a view that can present anything. That also
    /// keeps them anchored to the project they are about, which is where the menus that trigger
    /// them live.
    private var header: some View {
        HStack(spacing: Metrics.spacing) {
            disclosure

            RepoIcon(repo: repo)

            if isRenamingRepo {
                TextField("Project name", text: $repoDraft)
                    .textFieldStyle(.plain)
                    .font(Typo.title)
                    .focused($repoFieldFocused)
                    .onSubmit(commitRepoRename)
                    .onExitCommand { isRenamingRepo = false }
            } else {
                // A source list section header is usually set below its rows, which is right when
                // the header names a category ("Favorites", "Locations") and the rows are the
                // things. Here the header names a thing: a project, with its own icon, its own
                // menu and its own colour, and the rows are what is inside it. Mail's account
                // headers and Xcode's project group are the closer precedent, and both sit at
                // reading size in the heading weight. `Typo.title` is that, and it is what the
                // same project name is already set in on Home, so the two agree.
                //
                // The rows below are `Typo.body`, one weight lighter and one shade quieter, so
                // the pair reads as a heading and its contents rather than as two ranks of
                // similar grey text.
                Text(repo.name)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer(minLength: Metrics.spacingSmall)

            // Boxed to the tile's size at the other end of the row, so the header is bracketed by
            // two marks of one size rather than by an icon and a speck. The padding is the click
            // target, and it is inside the label because a button's hit area is its label, which
            // is why the `contentShape` outside the button widened nothing.
            //
            // Still hover-lit, and deliberately lit rather than revealed. Finder's own sidebar
            // headers do exactly this with Show and Hide: present at rest, quiet, and brought
            // forward under the pointer. Revealing it from nothing would make every header twitch
            // as the pointer crosses the list and would hide the control from anyone who never
            // gets a pointer near it, which is the whole of Full Keyboard Access and VoiceOver.
            // At the old size it was a hairline glyph that hover had to rescue; now hover only
            // has to say which project the click would land in.
            Button {
                onCreateWorkspace(repo)
            } label: {
                Label("New workspace in \(repo.name)", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    // One rung down from the project's name. It was set at the name's size to
                    // bracket the header with two marks of the tile's size, but the leading end of
                    // the header now carries two marks of its own, and a `+` that matches the
                    // heading is the loudest thing in a column it is the least important part of.
                    .font(Typo.label)
                    .frame(
                        width: SidebarMetrics.headerButton.width,
                        height: SidebarMetrics.headerButton.height
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
                    .background(
                        isHeaderHovered ? Palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHeaderHovered ? Palette.textPrimary : Palette.textSecondary)
            .help("New workspace in \(repo.name)")
        }
        .contentShape(Rectangle())
        .onHoverChange { isHeaderHovered = $0 }
        .contextMenu {
            Button("New workspace") { onCreateWorkspace(repo) }
            Button(repo.collapsed ? "Show workspaces" : "Hide workspaces") {
                Task { await app.toggleCollapsed(repo) }
            }
            Button("Rename", action: beginRepoRename)
            Button("Reveal in Finder") { Reveal.inFinder(repo.path) }
            Divider()
            Button("Remove project", role: .destructive) { isConfirmingRemove = true }
        }
        .confirmationDialog(
            "Remove \(repo.name)?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove project", role: .destructive, action: removeRepo)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bloom forgets this project and its workspaces. Nothing on disk is deleted.")
        }
    }

    /// The control that folds the project away, in a gutter of its own at the leading edge.
    ///
    /// It used to share the tile's box and appear only under the pointer, which spent no width on
    /// a chevron that is idle almost all the time. The cost was that it took the project's mark
    /// away to do it: the one thing in the header worth scanning vanished exactly when you looked
    /// at the header. A gutter costs eleven points and gives the tile back for good.
    ///
    /// Eleven points is also what sets the column relationship the rest of the pane hangs off.
    /// With the chevron at the leading edge and the tile behind it, a workspace row's status mark
    /// falls between the two: right of the chevron, left of the tile. That is what makes a project
    /// read as containing its rows. With the tile at the leading edge instead, as it was, the rows
    /// started right of the project's own mark and the column read the other way round.
    ///
    /// The chevron is the smallest mark in the pane on purpose. It is furniture: it says the thing
    /// beside it opens, and then it should get out of the way of everything that has something to
    /// say. Measured off the reference render at roughly five points across in a secondary ink.
    ///
    /// `Section(isExpanded:)` draws no triangle of its own here, captured with the pointer on a
    /// header and with it off, so this is the only disclosure control the header has. The binding
    /// stays because it is what tells the list to fold the rows away.
    ///
    /// A real `Button`, present at rest, so Full Keyboard Access can reach it and VoiceOver reads
    /// it with its expanded state as a value.
    private var disclosure: some View {
        Button {
            Task { await app.toggleCollapsed(repo) }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: SidebarMetrics.caretSize, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .rotationEffect(.degrees(repo.collapsed ? 0 : 90))
                .frame(width: SidebarMetrics.caretGutter, height: Metrics.repoIcon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The turn is movement, so it goes when Reduce Motion is on. Without it the chevron still
        // changes direction, it just arrives there rather than travelling.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: repo.collapsed)
        .accessibilityLabel(repo.collapsed ? "Show workspaces in \(repo.name)" : "Hide workspaces in \(repo.name)")
        .accessibilityValue(repo.collapsed ? "Collapsed" : "Expanded")
        .help(repo.collapsed ? "Show workspaces" : "Hide workspaces")
    }

    // MARK: - Rows

    private func row(_ workspace: Workspace) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isRunning: app.isRunning(workspace),
            renaming: $renaming
        )
        .tag(SidebarSelection.workspace(workspace.id))
        .draggable(workspace.id)
        .dropDestination(for: String.self) { items, _ in
            move(items.first, above: workspace)
        }
        .contextMenu {
            Button("Open in Editor") { Reveal.inEditor(workspace.path) }
            Button("Reveal in Finder") { Reveal.inFinder(workspace.path) }
            Button("Copy branch name") { copy(workspace.branch) }
            Divider()
            Button(workspace.pinned ? "Unpin" : "Pin") {
                Task { await app.togglePinned(workspace) }
            }
            Button("Rename") { renaming = workspace.id }
            Divider()
            // Straight through, with no dialog of its own. Whether this needs confirming is not
            // something this menu can know: it depends on what is uncommitted, what is running and
            // what GitHub says about the branch, and `AppModel.archive` is where all three come
            // together. Asking here as well meant a sheet on every archive, including the routine
            // one, which is exactly how a confirmation stops being read.
            //
            // Whether the branch goes too is the repository's setting, rather than a question
            // asked every time about a workspace that is usually finished with.
            Button("Archive", role: .destructive) { archive(workspace) }
        }
    }

    // MARK: - Actions

    /// The visible list can be filtered, so the drop target's position has to be translated back
    /// into the unfiltered order the store actually stores.
    private func move(_ draggedID: String?, above workspace: Workspace) -> Bool {
        guard let draggedID, draggedID != workspace.id else { return false }
        guard let moved = app.workspaces.first(where: { $0.id == draggedID }),
              moved.repoID == repo.id else { return false }

        let unfiltered = app.workspaces(in: repo)
        guard let index = unfiltered.firstIndex(where: { $0.id == workspace.id }) else {
            return false
        }
        Task { await app.reorder(moved, to: index) }
        return true
    }

    private func archive(_ workspace: Workspace) {
        Task { await app.archive(workspace) }
    }

    private func removeRepo() {
        Task { await app.removeRepository(repo) }
    }

    private func beginRepoRename() {
        repoDraft = repo.name
        isRenamingRepo = true
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            repoFieldFocused = true
        }
    }

    private func commitRepoRename() {
        let name = repoDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isRenamingRepo = false
        guard !name.isEmpty, name != repo.name else { return }
        Task { await app.rename(repo, to: name) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
