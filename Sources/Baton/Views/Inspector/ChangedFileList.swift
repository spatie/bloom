import SwiftUI
import BatonCore

/// What the agent touched, either as a flat list under pinned directory headers or as a directory
/// tree.
///
/// Both shapes exist for the same reason: the directory is said once, dimmed, and every row under
/// it is just a filename and its numbers. The flat list wins on a handful of files in two
/// directories, the tree wins once a change spreads across a package, so the choice is the user's
/// and it outlives the app.
///
/// Selection, hover, the revert dialog and the empty states live here rather than in either shape,
/// which is what keeps picking a file identical in both.
struct ChangedFileList: View {
    let model: WorkspaceModel

    @State private var hoveredPath: String?
    @State private var pendingRevert: ChangedFile?
    /// Derived from `model.changedFiles`, rebuilt only when that list changes. See
    /// `ChangedFileGroup`.
    @State private var groups: [ChangedFileGroup] = []
    /// Likewise for the tree. Only the shape that is on screen is built.
    @State private var treeRows: [ChangedFileTreeRow] = []
    /// Folders the user closed. Empty means everything is open, which is what a change of twenty
    /// files wants on first sight.
    @State private var collapsed: Set<String> = []

    @AppStorage(ChangedFilePresentation.storageKey) private var isTree = false

    var body: some View {
        Group {
            if model.changedFiles.isEmpty {
                empty
            } else if isTree {
                tree
            } else {
                list
            }
        }
        .onChange(of: model.changedFiles, initial: true) { _, _ in rebuild() }
        .onChange(of: isTree) { _, _ in rebuild() }
        // Attached to the list the rows live in, so the dialog animates out of the file it is
        // about rather than out of the window.
        .confirmationDialog(
            "Revert \(pendingRevert?.filename ?? "this file")?",
            isPresented: $pendingRevert.isPresent(),
            presenting: pendingRevert
        ) { file in
            Button("Revert", role: .destructive) { revert(file) }
            Button("Cancel", role: .cancel) {}
        } message: { file in
            Text(file.change == .untracked
                 ? "\(file.path) is untracked, so reverting deletes it. This cannot be undone."
                 : "Discards every change to \(file.path). This cannot be undone.")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            row(file)
                        }
                    } header: {
                        header(group.directory)
                    }
                }
            }
            .padding(.bottom, Metrics.spacingSmall)
        }
    }

    private var tree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(treeRows) { item in
                    treeRow(item)
                }
            }
            .padding(.vertical, InspectorLayout.tight)
        }
    }

    /// "No changes" and "git could not tell us" look identical unless they are said differently,
    /// and the second one quietly convinces the user their agent did nothing.
    @ViewBuilder
    private var empty: some View {
        if model.isLoadingChanges {
            LoadingView("Reading the worktree")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let problem = model.changesError {
            EmptyStateView(
                glyph: "exclamationmark.triangle",
                title: "Could not read the changes",
                message: problem,
                actionTitle: "Try again",
                action: refresh
            )
        } else {
            EmptyStateView(
                glyph: "checkmark.circle",
                title: "No changes yet",
                message: "Nothing in this worktree differs from \(model.workspace.baseBranch)."
            )
        }
    }

    private func header(_ directory: String) -> some View {
        HStack(spacing: Metrics.spacingSmall) {
            Image(systemName: "folder")
                .font(Typo.micro)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(directory.isEmpty ? "Repository root" : directory)
                .font(Typo.micro)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, InspectorLayout.inset)
        .padding(.vertical, Metrics.spacingSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken)
    }

    @ViewBuilder
    private func treeRow(_ item: ChangedFileTreeRow) -> some View {
        let indent = CGFloat(item.depth) * InspectorLayout.indentStep

        if let file = item.node.file {
            row(file, indent: indent)
        } else {
            ChangedFolderRow(
                name: item.node.name,
                path: item.node.path,
                isExpanded: !collapsed.contains(item.node.path),
                indent: indent,
                fullPath: fullPath(item.node.path),
                action: { toggle(item.node.path) }
            )
            .rowBackground(isSelected: false, isHovered: hoveredPath == item.node.path)
            .padding(.horizontal, Metrics.spacingSmall)
            .onHoverChange { hovering in hover(item.node.path, hovering) }
        }
    }

    private func row(_ file: ChangedFile, indent: CGFloat = 0) -> some View {
        let isSelected = model.selectedFilePath == file.path

        return ChangedFileRow(
            file: file,
            isSelected: isSelected,
            fullPath: fullPath(file.path),
            indent: indent,
            onSelect: { model.selectedFilePath = isSelected ? nil : file.path },
            onRevert: { pendingRevert = file }
        )
        // The fill is applied here rather than inside the row so that the row's own body can read
        // the selection out of the environment and invert its status letter accordingly.
        .rowBackground(isSelected: isSelected, isHovered: hoveredPath == file.path)
        .padding(.horizontal, Metrics.spacingSmall)
        .onHoverChange { hovering in hover(file.path, hovering) }
    }

    // MARK: - Actions

    /// Only the shape on screen is derived, because a running agent rewrites the changed file list
    /// every few seconds and the other shape would be thrown away unseen.
    private func rebuild() {
        if isTree {
            treeRows = ChangedFileTree.rows(
                from: ChangedFileTree.build(from: model.changedFiles),
                collapsed: collapsed
            )
            groups = []
        } else {
            groups = ChangedFileGroup.build(from: model.changedFiles)
            treeRows = []
        }
    }

    private func toggle(_ path: String) {
        if collapsed.contains(path) {
            collapsed.remove(path)
        } else {
            collapsed.insert(path)
        }
        rebuild()
    }

    private func hover(_ path: String, _ hovering: Bool) {
        hoveredPath = hovering ? path : (hoveredPath == path ? nil : hoveredPath)
    }

    private func fullPath(_ relative: String) -> String {
        (model.workspace.path as NSString).appendingPathComponent(relative)
    }

    private func refresh() {
        Task { await model.refreshChanges() }
    }

    /// Untracked files have no committed version to restore, so the only honest revert is a
    /// delete. Both paths go through git so the working tree and the index stay in step.
    private func revert(_ file: ChangedFile) {
        let worktree = model.workspace.path
        let arguments = file.change == .untracked
            ? ["clean", "-f", "--", file.path]
            : ["checkout", "--", file.path]

        Task {
            _ = try? await Shell.run("git", arguments, cwd: worktree, timeout: .seconds(20))
            await model.refreshChanges()
        }
    }
}
