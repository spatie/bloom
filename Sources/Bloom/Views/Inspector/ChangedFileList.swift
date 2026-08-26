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
    /// reader has been in the composer or a terminal. See `ListKeyboardHost`.
    @State private var quickLookArm = 0
    /// The row the keyboard is on, named by path.
    ///
    /// Not `model.selectedFilePath`, and it cannot be: in the tree shape a directory is a row too,
    /// and a directory is not a file the centre column can open. So this is what the highlight
    /// follows, and a cursor that lands on a file sets the model's selection as well, which is
    /// what keeps the two shapes and the review pane saying the same thing.
    @State private var cursor: String?
    /// Every row on screen in the order it is drawn, and the names type-select matches against.
    ///
    /// Derived in `rebuild` for the reason every other derived list in this file is: a running
    /// agent rewrites the changed files every few seconds and `body` runs far more often than
    /// that.
    @State private var rowPaths: [String] = []
    @State private var rowTitles: [String] = []
    /// The prefix somebody is typing, and the rest of the list's keyboard. See `ListKeyboard`.
    @State private var keyboard = ListKeyboard()
    /// Whether the arrow keys move this list, which is what decides between the emphasised
    /// selection fill and the quiet one. See `RowBackground`.
    @State private var hasKeyboard = false

    @AppStorage(ChangedFilePresentation.storageKey)
    private var isTree = ChangedFilePresentation.defaultsToTree

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if model.changedFiles.isEmpty {
                    empty
                } else if isTree {
                    tree
                } else {
                    list
                }
            }
            // The row an arrow key moved to comes into view, which is the other half of the key.
            // Only while this list holds the keyboard: a cursor that moved because the agent
            // rewrote the file list must not drag the reader's scroll position with it.
            .onChange(of: cursor) { _, path in
                guard hasKeyboard, let path else { return }
                proxy.scrollTo(path)
            }
        }
        // Arrows, Home and End, type-select, Return, and the space bar Quick Look that used to be
        // reachable only with the pointer. See `ListKeyboardHost`.
        .listKeyboard(
            hasKeyboard: $hasKeyboard,
            previewing: previewURL,
            armToken: quickLookArm,
            onKey: handle
        )
        .onChange(of: model.changedFiles, initial: true) { _, _ in
            rebuild()
            // A file the agent has just deleted stops being previewable without the selection
            // ever moving.
            refreshPreview()
        }
        // The keyboard follows a selection taken anywhere else: Command+Option+J, the review
        // pane's own walk, a file chip in the transcript.
        .onChange(of: model.selectedFilePath, initial: true) { _, path in
            if let path, path != cursor { cursor = path }
        }
        .onChange(of: cursor) { _, _ in refreshPreview() }
        .onChange(of: hasKeyboard) { _, focused in
            if !focused { keyboard.forgetTyping() }
        }
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
            // Escape keeps the changes. See the archive confirmation in `RootView` for why no
            // cancel button in this app carries `.keyboardShortcut(.defaultAction)`.
            Button("Keep the changes", role: .cancel) {}
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
            // The same inset the tree keeps, top and bottom. The flat list held four points at the
            // bottom and none at the top while the tree held two at both, so switching shape moved
            // every row two points and the pane looked like it had reloaded.
            .padding(.vertical, InspectorLayout.tight)
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
        // "Nobody has looked yet" first, because an empty list before git has answered is not an
        // answer. See `WorkspaceModel.hasReadChanges`.
        if model.isLoadingChanges || !model.hasReadChanges {
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
            // The sentence follows the scope. "Nothing in this worktree differs from main" under
            // a list narrowed to uncommitted work is a claim about the wrong comparison, and it
            // is the claim most likely to be believed.
            EmptyStateView(
                glyph: "checkmark.circle",
                title: "No changes yet",
                message: model.diffScope.emptyMessage(base: model.workspace.baseBranch)
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
            // The hover is the row's own, and the fill is painted by the wrapper rather than by
            // the row, for the two reasons `HoverRow` gives.
            HoverRow(isSelected: cursor == item.node.path, isFocused: hasKeyboard) {
                ChangedFolderRow(
                    name: item.node.name,
                    path: item.node.path,
                    isExpanded: !collapsed.contains(item.node.path),
                    depth: item.depth,
                    fullPath: fullPath(item.node.path),
                    action: { activate(folder: item.node.path) },
                    onOpenTerminal: {
                        FolderTerminalTab.open(folder: fullPath(item.node.path), in: model)
                    }
                )
                .equatable()
            }
            .padding(.horizontal, Metrics.spacingSmall)
        }
    }

    private func row(_ file: ChangedFile, depth: Int = 0) -> some View {
        let isSelected = cursor == file.path

        // The fill is applied outside the row rather than inside it, so that the row's own body
        // can read the selection out of the environment and invert its status letter accordingly.
        // That is also why the hover cannot simply be state on the row: see `HoverRow`.
        return HoverRow(isSelected: isSelected, isFocused: hasKeyboard) {
            ChangedFileRow(
                file: file,
                isSelected: isSelected,
                fullPath: fullPath(file.path),
                depth: depth,
                // Always a selection, never a toggle. Clicking the open row used to close the diff
                // under the list; there is no diff under the list any more, and a click that
                // deselected would now close nothing while making the row you just aimed at go
                // quiet.
                onSelect: { move(to: file.path) },
                onRevert: { pendingRevert = file }
            )
            .equatable()
        }
        .padding(.horizontal, Metrics.spacingSmall)
    }

    // MARK: - Actions

    /// Only the shape on screen is derived, because a running agent rewrites the changed file list
    /// every few seconds and the other shape would be thrown away unseen.
    ///
    /// Never animated. This is what a running agent's writes come through, and a list that slid
    /// every six seconds because a file gained a line would be the tree animating for a reason
    /// nobody gave it. Opening a folder is the one gesture that reflows: see `toggle`.
    private func rebuild() {
        if isTree {
            adopt(ChangedFileTree.rows(
                from: ChangedFileTree.build(from: model.changedFiles),
                collapsed: collapsed
            ))
        } else {
            groups = ChangedFileGroup.build(from: model.changedFiles)
            treeRows = []
            let files = groups.flatMap(\.files)
            rowPaths = files.map(\.path)
            rowTitles = files.map(\.filename)
            forgetMissingCursor()
        }
    }

    private func adopt(_ rows: [ChangedFileTreeRow]) {
        treeRows = rows
        groups = []
        rowPaths = rows.map(\.node.path)
        rowTitles = rows.map(\.node.name)
        forgetMissingCursor()
    }

    /// A file the agent reverted, or a directory that closed under the keyboard, leaves the cursor
    /// naming a row that is not drawn any more, and every key after that would be measured from
    /// nothing.
    private func forgetMissingCursor() {
        if let cursor, !rowPaths.contains(cursor) { self.cursor = nil }
    }

    /// A folder the reader just opened or closed, with the rows below it travelling to make room.
    /// See `TreeDisclosureMotion` for the threshold above which they stop travelling.
    ///
    /// The new rows are built before anything is written, because their count is what decides
    /// whether the write is animated at all.
    private func toggle(_ path: String) {
        var next = collapsed
        if next.contains(path) {
            next.remove(path)
        } else {
            next.insert(path)
        }

        let rows = ChangedFileTree.rows(
            from: ChangedFileTree.build(from: model.changedFiles),
            collapsed: next
        )
        let motion = TreeDisclosureMotion.rows(
            changing: abs(rows.count - treeRows.count), reduceMotion: reduceMotion
        )

        withAnimation(motion.animation) {
            collapsed = next
            adopt(rows)
        }
    }

    // MARK: - The keyboard

    /// The list's whole keyboard. Where a key lands is `ListKeyboard` and `TreeNavigation`, in the
    /// core, because it is a rule and a rule taken inside a view is a rule nothing can test. What
    /// is left here is applying the answer, which is the part that needs this window.
    ///
    /// False hands the key back to the responder chain. See `ListKeyOutcome` for why "nothing
    /// moved" is not that.
    private func handle(key: ListKey) -> Bool {
        let index = cursor.flatMap { rowPaths.firstIndex(of: $0) }

        // Only the tree shape has a left and a right. In the flat list both fall through to
        // `ListKeyboard`, which ignores them, and the window keeps them.
        if isTree, key == .left || key == .right {
            switch TreeNavigation.step(key, at: index, in: treeShape) {
            case .expand(let row), .collapse(let row):
                activate(folder: treeRows[row].node.path)
            case .move(let row):
                move(to: rowPaths[row])
            case .none:
                break
            }
            return true
        }

        switch keyboard.outcome(for: key, titles: rowTitles, current: index) {
        case .move(let row):
            move(to: rowPaths[row])
            return true
        case .activate:
            guard let index else { return false }
            activate(row: index)
            return true
        case .handled:
            return true
        case .ignored:
            return false
        }
    }

    /// The tree as its keyboard sees it. A node with no file behind it is a directory, and the
    /// `collapsed` set is the inverse of open, because a change of twenty files wants everything
    /// open on first sight.
    private var treeShape: [TreeRow] {
        treeRows.map {
            TreeRow(
                depth: $0.depth,
                isDirectory: $0.node.file == nil,
                isExpanded: !collapsed.contains($0.node.path)
            )
        }
    }

    /// Moves the highlight, and opens the file under it.
    ///
    /// Arrowing onto a row opens it rather than only highlighting it, which is what a click on the
    /// same row does and what this list's selection has always meant: the highlighted row is the
    /// review that is open. Xcode's navigator behaves the same way. A directory row has nothing to
    /// open and only takes the highlight.
    private func move(to path: String) {
        cursor = path

        if let file = model.changedFiles.first(where: { $0.path == path }) {
            model.selectedFilePath = file.path
            FileReview.open(path: file.path, in: model)
        }

        // Opening a review moves the centre column, so the keyboard is put back here afterwards
        // rather than left wherever that landed.
        quickLookArm += 1
    }

    /// Return. A directory opens or closes, a file opens, and in the flat list every row is a file.
    private func activate(row index: Int) {
        if isTree, treeRows.indices.contains(index), treeRows[index].node.file == nil {
            activate(folder: treeRows[index].node.path)
            return
        }
        move(to: rowPaths[index])
    }

    private func activate(folder path: String) {
        cursor = path
        toggle(path)
        quickLookArm += 1
    }

    private func fullPath(_ relative: String) -> String {
        (model.workspace.path as NSString).appendingPathComponent(relative)
    }

    /// Follows the cursor rather than the model's selection, so the space bar previews the row
    /// the keyboard is actually on. A directory resolves to nothing, which disarms the preview
    /// rather than opening a panel on a folder.
    private func refreshPreview() {
        previewURL = cursor.flatMap { QuickLookTarget.url(for: fullPath($0)) }
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
