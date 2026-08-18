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
/// Collapsing is the list's own disclosure triangle bound to the repo's stored `collapsed` flag,
/// rather than a chevron we draw and a tap gesture we interpret.
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

    @State private var isRenamingRepo = false
    @State private var repoDraft = ""
    @FocusState private var repoFieldFocused: Bool

    @State private var archiveTarget: Workspace?
    @State private var isConfirmingRemove = false
    /// Only the `+` reacts to it, so it belongs to this header rather than to a hover id shared
    /// across the whole list.
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
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .fill(Color(hexString: repo.accent))
                .frame(width: Metrics.swatch, height: Metrics.swatch)
                .accessibilityHidden(true)

            if isRenamingRepo {
                TextField("Project name", text: $repoDraft)
                    .textFieldStyle(.plain)
                    .focused($repoFieldFocused)
                    .onSubmit(commitRepoRename)
                    .onExitCommand { isRenamingRepo = false }
            } else {
                Text(repo.name)
                    .lineLimit(1)
            }

            Spacer(minLength: Metrics.spacingSmall)

            // The sidebar's glyph box, rather than whatever the list's section header font hands
            // down: a header is set a size below its rows, and `.imageScale(.small)` took another
            // bite out of that, which left a speck. A box is also what centres the plus against
            // the name, since the two are then centred as boxes rather than as a word and a mark.
            // The padding is the click target, and it is inside the label because a button's hit
            // area is its label, which is why the `contentShape` outside the button widened
            // nothing.
            Button {
                onCreateWorkspace(repo)
            } label: {
                Label("New workspace in \(repo.name)", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .font(Typo.label)
                    .frame(width: Metrics.glyph, height: Metrics.glyph)
                    .padding(.horizontal, Metrics.spacingSmall)
                    .padding(.vertical, Metrics.spacingTight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHeaderHovered ? Palette.textSecondary : Palette.textTertiary)
            .help("New workspace in \(repo.name)")
        }
        .contentShape(Rectangle())
        .onHoverChange { isHeaderHovered = $0 }
        .contextMenu {
            Button("New workspace") { onCreateWorkspace(repo) }
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
