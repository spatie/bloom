import SwiftUI
import BloomCore

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
    /// A revert that failed, so the user hears about it. It used to be a `try?` that threw the
    /// error away and refreshed the list, which left a file that had not been reverted looking
    /// exactly like one that had.
    @State private var revertProblem: RevertProblem?
    /// Derived from `model.changedFiles`, rebuilt only when that list changes. See
    /// `ChangedFileGroup`.
    @State private var groups: [ChangedFileGroup] = []
    /// Likewise for the tree. Only the shape that is on screen is built.
    @State private var treeRows: [ChangedFileTreeRow] = []
    /// Folders the user closed. Empty means everything is open, which is what a change of twenty
    /// files wants on first sight.
    @State private var collapsed: Set<String> = []
    /// Resolved when the selection moves rather than in `body`, which runs again on every hover.
    @State private var previewURL: URL?
    /// Bumped on every row activation, which is what puts the keyboard back on the list after the
    /// reader has been in the composer or a terminal. See `QuickLookHost`.
    @State private var quickLookArm = 0

    @AppStorage(ChangedFilePresentation.storageKey)
    private var isTree = ChangedFilePresentation.defaultsToTree

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
        // Space bar Quick Look, the way Finder does it. Behind the rows, so it takes no clicks.
        .background(QuickLookHost(url: previewURL, armToken: quickLookArm))
        .onChange(of: model.changedFiles, initial: true) { _, _ in
            rebuild()
            // A file the agent has just deleted stops being previewable without the selection
            // ever moving.
            refreshPreview()
        }
        .onChange(of: model.selectedFilePath, initial: true) { _, _ in refreshPreview() }
        .onChange(of: isTree) { _, _ in rebuild() }
        // Attached to the list the rows live in, so the dialog animates out of the file it is
        // about rather than out of the window.
        .confirmationDialog(
            "Revert \(pendingRevert?.filename ?? "this file")?",
            isPresented: $pendingRevert.isPresent(),
            titleVisibility: .visible,
            presenting: pendingRevert
        ) { file in
            Button("Revert and lose those changes", role: .destructive) { revert(file) }
            Button("Keep the changes", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { file in
            // The same sentence the header bar's Revert shows, from the same place, because it is
            // the same command on the same file and two wordings would eventually describe two
            // different operations.
            Text(FileRevert.losses(
                for: file,
                in: model.workspace,
                hasDraft: FileEditSession.shared.isDirty(fullPath(file.path))
            ))
        }
        .alert(
            "Could not revert \(revertProblem?.filename ?? "the file")",
            isPresented: $revertProblem.isPresent(),
            presenting: revertProblem
        ) { _ in
        } message: { problem in
            Text(problem.message)
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
                        header(group)
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

    /// The same shape as the checks list's section header, which is the only other pinned header
    /// in this column: a name at the pane's own inset, then how many rows are under it.
    ///
    /// No glyph. A folder icon here started the label six points inside the pane inset and six
    /// points outside the filenames below it, which is a stagger that belongs to neither.
    private func header(_ group: ChangedFileGroup) -> some View {
        HStack(spacing: Metrics.spacingSmall) {
            Text(group.directory.isEmpty ? "Repository root" : group.directory)
                .font(Typo.caption)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            Text("\(group.files.count)")
                .font(Typo.micro)
                .monospacedDigit()
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, InspectorLayout.inset)
        .padding(.vertical, Metrics.spacingSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken)
    }

    @ViewBuilder
    private func treeRow(_ item: ChangedFileTreeRow) -> some View {
        if let file = item.node.file {
            row(file, depth: item.depth)
        } else {
            ChangedFolderRow(
                name: item.node.name,
                path: item.node.path,
                isExpanded: !collapsed.contains(item.node.path),
                depth: item.depth,
                fullPath: fullPath(item.node.path),
                action: { toggle(item.node.path) }
            )
            .rowBackground(isSelected: false, isHovered: hoveredPath == item.node.path)
            .padding(.horizontal, Metrics.spacingSmall)
            .onHoverChange { hovering in hover(item.node.path, hovering) }
        }
    }

    private func row(_ file: ChangedFile, depth: Int = 0) -> some View {
        let isSelected = model.selectedFilePath == file.path

        return ChangedFileRow(
            file: file,
            isSelected: isSelected,
            fullPath: fullPath(file.path),
            depth: depth,
            // Always a selection, never a toggle. Clicking the open row used to close the diff
            // under the list; there is no diff under the list any more, and a click that
            // deselected would now close nothing while making the row you just aimed at go quiet.
            onSelect: {
                model.selectedFilePath = file.path
                FileReview.open(path: file.path, in: model)
                quickLookArm += 1
            },
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

    private func refreshPreview() {
        previewURL = model.selectedFilePath.flatMap { QuickLookTarget.url(for: fullPath($0)) }
    }

    private func refresh() {
        Task { await model.refreshChanges() }
    }

    /// Through `FileRevert`, which is the one place that knows what reverting a file means.
    ///
    /// This used to run its own pair of git commands, and they were not the same operation: an
    /// untracked file was destroyed with `git clean -f` where `FileRevert` moves it to the Trash,
    /// and a tracked one was restored from the index rather than from the merge base, so the two
    /// Revert buttons in this column gave the file two different contents. Renames were handled by
    /// neither half.
    private func revert(_ file: ChangedFile) {
        let workspace = model.workspace
        let absolute = fullPath(file.path)
        Task {
            // The draft goes with the file, exactly as it does from the header bar. Left behind,
            // an open Edit pane would keep offering to save the text that was just reverted.
            FileEditSession.shared.discard(path: absolute)
            if let message = await FileRevert.revert(file: file, in: workspace) {
                revertProblem = RevertProblem(filename: file.filename, message: message)
            }
            await model.refreshChanges()
        }
    }

    private struct RevertProblem: Identifiable {
        let id = UUID()
        var filename: String
        var message: String
    }
}
