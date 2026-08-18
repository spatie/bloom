import SwiftUI
import BatonCore

/// The whole worktree, not just what changed.
///
/// `git ls-files` is asked once and turned into a directory index. Rows are then produced only
/// for directories the user actually opened, so a repository with fifty thousand files costs one
/// subprocess and a handful of views rather than a tree of fifty thousand nodes.
struct FileTreeView: View {
    let model: WorkspaceModel

    @State private var children: [String: [FileTreeNode]] = [:]
    @State private var expanded: Set<String> = []
    @State private var selection: String?
    @State private var hovered: String?
    @State private var isLoading = true

    /// The flattened row list, rebuilt when the listing loads or a folder opens rather than on
    /// every redraw. Walking the index inside `body` meant re-walking it for every layout pass.
    @State private var rows: [FileTreeRowItem] = []
    /// Likewise: this used to be a computed `Set` read once per row, so it was rebuilt from the
    /// whole changed file list for every visible row on every pass.
    @State private var changedPaths: Set<String> = []

    private struct LoadID: Hashable {
        var workspaceID: String
        var workspacePath: String
    }

    var body: some View {
        VSplitLayout(
            top: { tree },
            bottom: { detail },
            hasBottom: selection != nil
        )
        .task(id: LoadID(workspaceID: model.workspace.id, workspacePath: model.workspace.path)) {
            await load()
        }
        .onChange(of: model.changedFiles, initial: true) { _, files in
            changedPaths = Set(files.map(\.path))
        }
    }

    // MARK: - Tree

    @ViewBuilder
    private var tree: some View {
        if isLoading {
            LoadingView("Listing the worktree")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if children.isEmpty {
            EmptyStateView(
                glyph: "folder",
                title: "Nothing tracked",
                message: "Git knows about no files in this worktree yet."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { item in
                        row(item)
                    }
                }
                .padding(.vertical, InspectorLayout.tight)
            }
        }
    }

    private func row(_ item: FileTreeRowItem) -> some View {
        let path = item.node.path

        return FileTreeRow(
            item: item,
            isExpanded: expanded.contains(path),
            isChanged: changedPaths.contains(path),
            isSelected: selection == path,
            isHovered: hovered == path,
            fullPath: fullPath(path),
            action: { activate(item.node) }
        )
        .onHoverChange { hovering in
            hovered = hovering ? path : (hovered == path ? nil : hovered)
        }
    }

    // MARK: - Detail

    /// A changed file is more usefully read as a diff, so the tree hands those to `DiffView` and
    /// only renders raw contents for files nobody has touched.
    @ViewBuilder
    private var detail: some View {
        if let selection {
            if let changed = model.changedFiles.first(where: { $0.path == selection }) {
                DiffView(model: model, file: changed)
            } else {
                FilePreview(model: model, path: selection)
            }
        }
    }

    // MARK: - Actions

    /// A directory opens or closes, a file is selected, and a file the agent touched also becomes
    /// the inspector's selected diff.
    private func activate(_ node: FileTreeNode) {
        guard node.isDirectory else {
            selection = selection == node.path ? nil : node.path
            if changedPaths.contains(node.path) { model.selectedFilePath = node.path }
            return
        }

        if expanded.contains(node.path) {
            expanded.remove(node.path)
        } else {
            expanded.insert(node.path)
        }
        rebuildRows()
    }

    private func rebuildRows() {
        rows = FileTreeRowItem.flatten(children: children, expanded: expanded)
    }

    private func fullPath(_ relative: String) -> String {
        (model.workspace.path as NSString).appendingPathComponent(relative)
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        let worktree = model.workspace.path

        let paths = await Task.detached(priority: .userInitiated) { () -> [String] in
            let result = try? await Shell.run(
                "git",
                ["ls-files", "--cached", "--others", "--exclude-standard"],
                cwd: worktree,
                timeout: .seconds(30)
            )
            return result?.lines ?? []
        }.value

        guard !Task.isCancelled else { return }
        children = FileTreeNode.index(paths)
        rebuildRows()
        isLoading = false
    }
}
