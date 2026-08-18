import SwiftUI
import AppKit
import BatonCore

/// One project and its workspaces, as a collapsible section of the source list.
///
/// The section owns the interaction that surrounds a row (context menus, drag to reorder, the
/// archive confirmation) while `WorkspaceRow` stays a pure drawing of a workspace. Splitting it
/// this way keeps the row cheap to redraw, which matters because a running agent updates its diff
/// stat every few seconds.
///
/// Collapsing is the list's own disclosure triangle bound to the repo's stored `collapsed` flag,
/// rather than a chevron we draw and a tap gesture we interpret.
struct RepoSection: View {
    var repo: Repo
    var filter: SidebarFilter
    @Binding var hovered: String?
    @Binding var renaming: String?
    /// Raised to the sidebar, which owns the create sheet.
    var onCreateWorkspace: (Repo) -> Void

    @Environment(AppModel.self) private var app

    @State private var isRenamingRepo = false
    @State private var repoDraft = ""
    @FocusState private var repoFieldFocused: Bool

    @State private var archiveTarget: Workspace?
    @State private var isConfirmingRemove = false

    private var rows: [Workspace] {
        app.workspaces(in: repo).filter { filter.accepts($0) }
    }

    var body: some View {
        Section(isExpanded: isExpanded) {
            ForEach(rows) { workspace in
                row(workspace)
            }
            if rows.isEmpty {
                Text(filter == .all ? "No workspaces yet" : "Nothing matches the filter")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
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

    private var headerID: String { "repo:\(repo.id)" }

    /// The confirmations hang off the header rather than off the `Section`, because a section is
    /// a layout instruction to the list rather than a view that can present anything.
    private var header: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .fill(Color(hexString: repo.accent))
                .frame(width: Self.swatch, height: Self.swatch)

            if isRenamingRepo {
                TextField("", text: $repoDraft)
                    .textFieldStyle(.plain)
                    .focused($repoFieldFocused)
                    .onSubmit { commitRepoRename() }
                    .onExitCommand { isRenamingRepo = false }
            } else {
                Text(repo.name)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                onCreateWorkspace(repo)
            } label: {
                Image(systemName: "plus")
                    .imageScale(.small)
                    .foregroundStyle(hovered == headerID ? Palette.textSecondary : Palette.textTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New workspace in \(repo.name)")
        }
        .contentShape(Rectangle())
        .onHoverChange { inside in
            hovered = inside ? headerID : (hovered == headerID ? nil : hovered)
        }
        .contextMenu {
            Button("New workspace") { onCreateWorkspace(repo) }
            Button("Rename") { beginRepoRename() }
            Button("Reveal in Finder") { Reveal.inFinder(repo.path) }
            Divider()
            Button("Remove project", role: .destructive) { isConfirmingRemove = true }
        }
        .confirmationDialog(
            archiveTarget.map { "Archive \($0.name)?" } ?? "Archive workspace?",
            isPresented: Binding(
                get: { archiveTarget != nil },
                set: { if !$0 { archiveTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = archiveTarget {
                Button("Archive, keep \(target.branch)", role: .destructive) {
                    archive(target, deleteBranch: false)
                }
                Button("Archive and delete \(target.branch)", role: .destructive) {
                    archive(target, deleteBranch: true)
                }
            }
            Button("Cancel", role: .cancel) { archiveTarget = nil }
        } message: {
            if let target = archiveTarget {
                Text("The worktree at \(target.path) is removed. The branch \(target.branch) is kept unless you delete it here.")
            }
        }
        .confirmationDialog(
            "Remove \(repo.name)?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove project", role: .destructive) {
                Task { await app.removeRepository(repo) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Baton forgets this project and its workspaces. Nothing on disk is deleted.")
        }
    }

    /// Small enough to read as a project marker rather than as a control.
    private static let swatch: CGFloat = 9

    // MARK: - Rows

    private func row(_ workspace: Workspace) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isSelected: app.selection.workspaceID == workspace.id,
            isRunning: app.isRunning(workspace),
            renaming: $renaming
        )
        .tag(SidebarSelection.workspace(workspace.id))
        .draggable(workspace.id)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first, dragged != workspace.id else { return false }
            guard let moved = app.workspaces.first(where: { $0.id == dragged }),
                  moved.repoID == repo.id else { return false }
            // The visible list can be filtered, so the drop target's position has to be
            // translated back into the unfiltered order the store actually stores.
            let unfiltered = app.workspaces(in: repo)
            guard let index = unfiltered.firstIndex(where: { $0.id == workspace.id }) else {
                return false
            }
            Task { await app.reorder(moved, to: index) }
            return true
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

    private func archive(_ workspace: Workspace, deleteBranch: Bool) {
        archiveTarget = nil
        Task { await app.archive(workspace, deleteBranch: deleteBranch) }
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
