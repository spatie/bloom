import SwiftUI
import AppKit
import BatonCore

/// One project and its workspaces, as a pinned section of the sidebar list.
///
/// The section owns the interaction that surrounds a row (selection, context menus, drag to
/// reorder, the archive confirmation) while `WorkspaceRow` stays a pure drawing of a workspace.
/// Splitting it this way keeps the row cheap to redraw, which matters because a running agent
/// updates its diff stat every few seconds.
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
        Section {
            if !repo.collapsed {
                ForEach(rows) { workspace in
                    row(workspace)
                }
                if rows.isEmpty {
                    Text(filter == .all ? "No workspaces yet" : "Nothing matches the filter")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, 14)
                        .frame(height: 22, alignment: .leading)
                }
            }
        } header: {
            header
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

    // MARK: - Header

    private var headerID: String { "repo:\(repo.id)" }

    private var header: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hexString: repo.accent))
                .frame(width: 9, height: 9)

            if isRenamingRepo {
                TextField("", text: $repoDraft)
                    .textFieldStyle(.plain)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .focused($repoFieldFocused)
                    .onSubmit { commitRepoRename() }
                    .onExitCommand { isRenamingRepo = false }
            } else {
                Text(repo.name)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Palette.textTertiary)
                    .rotationEffect(.degrees(repo.collapsed ? -90 : 0))
            }

            Spacer(minLength: 4)

            Button {
                onCreateWorkspace(repo)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovered == headerID ? Palette.textSecondary : Palette.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New workspace in \(repo.name)")
        }
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(Palette.sidebar)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenamingRepo else { return }
            Task { await app.toggleCollapsed(repo) }
        }
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
    }

    // MARK: - Rows

    private func row(_ workspace: Workspace) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isSelected: app.selection.workspaceID == workspace.id,
            isHovered: hovered == workspace.id,
            isRunning: app.isRunning(workspace),
            renaming: $renaming
        )
        .padding(.horizontal, 8)
        .onHoverChange { inside in
            hovered = inside ? workspace.id : (hovered == workspace.id ? nil : hovered)
        }
        .onTapGesture {
            guard renaming != workspace.id else { return }
            renaming = nil
            app.selection = .workspace(workspace.id)
        }
        .draggable(workspace.id)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first, dragged != workspace.id else { return false }
            guard let moved = app.workspaces.first(where: { $0.id == dragged }),
                  moved.repoID == repo.id else { return false }
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
