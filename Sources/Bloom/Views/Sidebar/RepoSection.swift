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

    @State private var archiveTarget: Workspace?
    @State private var isConfirmingRemove = false
    /// The `+` lights and the project's tile turns into a caret on it, together, so it belongs to
    /// this header rather than to a hover id shared across the whole list.
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
                    .font(Typo.title)
                    .frame(width: Metrics.repoIcon, height: Metrics.repoIcon)
                    .padding(Metrics.spacingSmall)
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
        .padding(.vertical, Metrics.spacingTight)
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
            archiveTarget.map { "Archive \($0.name)?" } ?? "Archive workspace?",
            isPresented: $archiveTarget.isPresent(),
            titleVisibility: .visible,
            presenting: archiveTarget
        ) { target in
            Button("Archive, keep \(target.branch)", role: .destructive) {
                archive(target, deleteBranch: false)
            }
            Button("Archive and delete \(target.branch)", role: .destructive) {
                archive(target, deleteBranch: true)
            }
            Button("Cancel", role: .cancel) { archiveTarget = nil }
        } message: { target in
            Text("The worktree at \(target.path) is removed. The branch \(target.branch) is kept unless you delete it here.")
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

    /// The project's mark, which becomes the control that collapses it while the pointer is on
    /// the header.
    ///
    /// The two things a header's leading slot could hold are wanted at different moments: the
    /// tile is what you read while scanning a column of projects, the caret is what you reach for
    /// once you have decided to fold one away. Sharing one slot spends no width on a chevron that
    /// is idle almost all the time, and it puts the control under the pointer that is already
    /// there. Both are drawn in the same box and centred on the same point, so the name beside
    /// them does not move by a pixel when they trade places, and they cross fade rather than
    /// snapping, which is what makes it read as one mark changing rather than two marks blinking.
    ///
    /// The same `isHeaderHovered` lights the `+` at the other end, so the header has one hover
    /// behaviour rather than two controls each appearing on their own terms.
    ///
    /// This is the only disclosure control the header has. `Section(isExpanded:)` was documented
    /// here as the list drawing its own triangle for us; captured with the pointer on a header
    /// and with it off, the list draws nothing at all, so collapsing a project had no affordance
    /// in the window and the stored flag could only ever be set by restoring a session. The
    /// binding stays because it is what tells the list to fold the rows away.
    ///
    /// The button is present at rest, not conjured by hover: only its drawing changes. That is
    /// what keeps it reachable by Full Keyboard Access and announced to VoiceOver, which a
    /// control that exists only under a pointer never is.
    private var disclosure: some View {
        Button {
            Task { await app.toggleCollapsed(repo) }
        } label: {
            ZStack {
                RepoIcon(repo: repo)
                    .opacity(isHeaderHovered ? 0 : 1)

                Image(systemName: "chevron.right")
                    .font(Typo.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.textSecondary)
                    .rotationEffect(.degrees(repo.collapsed ? 0 : 90))
                    .opacity(isHeaderHovered ? 1 : 0)
            }
            .frame(width: Metrics.repoIcon, height: Metrics.repoIcon)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.12), value: isHeaderHovered)
        // The turn is movement, so it goes when Reduce Motion is on. The cross fade stays: a fade
        // is what that setting asks for in place of a movement, not something it also forbids.
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
            Button("Archive", role: .destructive) { archiveTarget = workspace }
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

    private func archive(_ workspace: Workspace, deleteBranch: Bool) {
        archiveTarget = nil
        Task { await app.archive(workspace, deleteBranch: deleteBranch) }
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
