import SwiftUI
import BloomCore

/// The whole worktree, not just what changed.
///
/// `git ls-files` is asked once and turned into a directory index. Rows are then produced only
/// for directories the user actually opened, so a repository with fifty thousand files costs one
/// subprocess and a handful of views rather than a tree of fifty thousand nodes.
struct FileTreeView: View {
    let model: WorkspaceModel

    /// Which folders this reader has opened. The listing itself is the model's: see
    /// `WorkspaceModel.fileTree`, and the note there for why it cannot live in this view.
    @State private var expanded: Set<String> = []
    @State private var selection: String?

    /// The flattened row list, rebuilt when the listing loads or a folder opens rather than on
    /// every redraw. Walking the index inside `body` meant re-walking it for every layout pass.
    @State private var rows: [FileTreeRowItem] = []
    /// Likewise: this used to be a computed `Set` read once per row, so it was rebuilt from the
    /// whole changed file list for every visible row on every pass.
    @State private var changedPaths: Set<String> = []
    /// Resolved when the selection moves rather than in `body`, which runs again on every hover.
    @State private var previewURL: URL?
    /// Bumped on every row activation, which is what puts the keyboard back on the tree after the
    /// reader has been in the composer or a terminal. See `ListKeyboardHost`.
    @State private var quickLookArm = 0
    /// The names type-select matches against, in the order the rows are drawn. Derived with the
    /// rows for the same reason they are: walking the index inside `body` meant re-walking it for
    /// every layout pass.
    @State private var rowTitles: [String] = []
    /// The prefix somebody is typing, and the rest of the tree's keyboard. See `ListKeyboard`.
    @State private var keyboard = ListKeyboard()
    /// Whether the arrow keys move this tree, which is what decides between the emphasised
    /// selection fill and the quiet one. See `RowBackground`.
    @State private var hasKeyboard = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct LoadID: Hashable {
        var workspaceID: WorkspaceID
        var workspacePath: String
    }

    var body: some View {
        ScrollViewReader { proxy in
            tree
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The row an arrow key moved to comes into view, which is the other half of the
                // key. Only while the tree holds the keyboard, so a listing that arrives while the
                // reader is elsewhere does not move what they are looking at.
                .onChange(of: selection) { _, path in
                    guard hasKeyboard, let path else { return }
                    proxy.scrollTo(path)
                }
        }
        // Arrows, left and right through the folders, Home and End, type-select, Return, and the
        // space bar Quick Look that used to be reachable only with the pointer. See
        // `ListKeyboardHost`.
        .listKeyboard(
            hasKeyboard: $hasKeyboard,
            previewing: previewURL,
            armToken: quickLookArm,
            onKey: handle
        )
        .task(id: LoadID(workspaceID: model.workspace.id, workspacePath: model.workspace.path)) {
            // Nothing is thrown away first. A workspace whose listing has already been read draws
            // it on the frame it arrives on, and this returns without a subprocess.
            expanded = []
            await model.refreshFileTree()
        }
        .onChange(of: model.fileTree, initial: true) { _, _ in rebuildRows() }
        .onChange(of: hasKeyboard) { _, focused in
            if !focused { keyboard.forgetTyping() }
        }
        .onChange(of: selection) { _, path in
            previewURL = path.flatMap { QuickLookTarget.url(for: fullPath($0)) }
        }
        .onChange(of: model.changedFiles, initial: true) { _, files in
            changedPaths = Set(files.map(\.path))
        }
    }

    // MARK: - Tree

    @ViewBuilder
    private var tree: some View {
        if !model.hasReadFileTree {
            LoadingView("Listing the worktree")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.fileTree.isEmpty {
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

        // The fill is applied outside the row rather than inside it, so the row can read the
        // selection back out of the environment and invert the dot that marks a changed file. That
        // is also why the hover cannot simply be state on the row: see `HoverRow`.
        return HoverRow(isSelected: selection == path, isFocused: hasKeyboard) {
            FileTreeRow(
                item: item,
                isExpanded: expanded.contains(path),
                isChanged: changedPaths.contains(path),
                fullPath: fullPath(path),
                action: { activate(item.node) }
            )
            .equatable()
        }
        .padding(.horizontal, Metrics.spacingSmall)
    }

    // MARK: - Actions

    /// A directory opens or closes, and a file opens in the centre column: as a diff if the agent
    /// touched it, as its own contents if it did not. The tree keeps its own selection for the
    /// highlight and for Quick Look, and a file the agent touched also becomes the changed list's
    /// selection, so the two tabs of this column agree about what is open.
    private func activate(_ node: FileTreeNode) {
        quickLookArm += 1

        guard node.isDirectory else {
            selection = node.path
            if changedPaths.contains(node.path) { model.selectedFilePath = node.path }
            FileReview.open(path: node.path, in: model)
            return
        }

        toggle(node)
    }

    /// Never animated. The listing lands once when the workspace opens, and eight thousand rows
    /// arriving is the pane being pointed somewhere else rather than anything the reader did.
    private func rebuildRows() {
        adopt(FileTreeRowItem.flatten(children: model.fileTree, expanded: expanded))
    }

    private func adopt(_ items: [FileTreeRowItem]) {
        rows = items
        rowTitles = items.map(\.node.name)

        // A folder that closed under the keyboard takes its children off the screen, and a cursor
        // naming a row that is not drawn any more would leave every key after it measured from
        // nothing.
        if let selection, !items.contains(where: { $0.node.path == selection }) {
            self.selection = nil
        }
    }

    // MARK: - The keyboard

    /// The tree's whole keyboard. Where a key lands is `ListKeyboard` and `TreeNavigation`, in the
    /// core, because it is a rule and a rule taken inside a view is a rule nothing can test.
    ///
    /// **The arrows move the highlight and nothing else here, where in the changed file list they
    /// open the row as well.** The two lists mean different things by a selection. A changed file
    /// IS the review that is open, and walking the change is the point of that list, which is what
    /// Command+Option+J already does to it. This tree is the whole worktree, tens of thousands of
    /// files in a large repository, and opening each one on the way past would read a file off
    /// disk per keystroke to show the reader something they were only passing over. Return opens,
    /// which is what an outline view on this platform does.
    private func handle(key: ListKey) -> Bool {
        let index = selection.flatMap { path in rows.firstIndex { $0.node.path == path } }

        if key == .left || key == .right {
            switch TreeNavigation.step(key, at: index, in: treeShape) {
            case .expand(let row), .collapse(let row):
                toggle(rows[row].node)
            case .move(let row):
                selection = rows[row].node.path
            case .none:
                break
            }
            return true
        }

        switch keyboard.outcome(for: key, titles: rowTitles, current: index) {
        case .move(let row):
            selection = rows[row].node.path
            return true
        case .activate:
            guard let index else { return false }
            activate(rows[index].node)
            return true
        case .handled:
            return true
        case .ignored:
            return false
        }
    }

    /// The tree as its keyboard sees it. `expanded` is what the reader opened, so a directory
    /// nobody has touched is closed, which is the opposite default from the changed file tree and
    /// right for a listing this size.
    private var treeShape: [TreeRow] {
        rows.map {
            TreeRow(
                depth: $0.depth,
                isDirectory: $0.node.isDirectory,
                isExpanded: expanded.contains($0.node.path)
            )
        }
    }

    /// The one place in this view that animates: a folder the reader just opened or closed, with
    /// the rows below it travelling to make room. See `TreeDisclosureMotion` for the threshold
    /// above which they stop travelling and simply arrive.
    ///
    /// The new rows are flattened before anything is written, because their count is what decides
    /// whether the write is animated at all.
    private func toggle(_ node: FileTreeNode) {
        var opened = expanded
        if opened.contains(node.path) {
            opened.remove(node.path)
        } else {
            opened.insert(node.path)
        }

        let items = FileTreeRowItem.flatten(children: model.fileTree, expanded: opened)
        let motion = TreeDisclosureMotion.rows(
            changing: abs(items.count - rows.count), reduceMotion: reduceMotion
        )

        // Outside the transaction, so the highlight lands with the click rather than fading in
        // behind the rows.
        selection = node.path

        withAnimation(motion.animation) {
            expanded = opened
            adopt(items)
        }
    }

    private func fullPath(_ relative: String) -> String {
        (model.workspace.path as NSString).appendingPathComponent(relative)
    }

}
