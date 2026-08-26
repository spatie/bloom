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
    ///
    /// **A live filter never writes to this**, which is what lets a filter be typed and deleted
    /// without costing somebody the place they had opened their way down to. See `filterOpen`.
    @State private var expanded: Set<String> = []
    @State private var selection: String?

    /// What is in the filter field.
    @State private var query = ""
    /// What the last needle made of the listing, or nil when the field is empty. Nil is not the
    /// same answer as an outcome with nothing in it: one draws the whole tree, the other says
    /// nothing matched. See `FileTreeFilter`.
    @State private var filtered: FileTreeFilter.Outcome?
    /// The folders that are open while a filter is live: the ones holding a match, plus whatever
    /// the reader has opened or closed since. Thrown away with the filter, so clearing the field
    /// puts the tree back exactly as they left it.
    @State private var filterOpen: Set<String> = []

    /// The flattened row list, rebuilt when the listing loads, a folder opens or the needle
    /// changes, rather than on every redraw. Walking the index inside `body` meant re-walking it
    /// for every layout pass, and the filter walks more of it than anything else here does.
    @State private var rows: [FileTreeRowItem] = []
    /// Likewise: this used to be a computed `Set` read once per row, so it was rebuilt from the
    /// whole changed file list for every visible row on every pass.
    @State private var changedPaths: Set<String> = []
    /// Resolved when the selection moves rather than in `body`, which runs again on every hover.
    @State private var previewURL: URL?
    /// Bumped whenever the keyboard should be on the tree: every row activation, which is what
    /// puts it back after the reader has been in the composer or a terminal, and Return or a
    /// second Escape in the filter field. See `ListKeyboardHost`, whose `armToken` this is.
    @State private var keyboardArm = 0
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
        VStack(spacing: 0) {
            // Only over a listing there is something to narrow. A filter above "Nothing tracked"
            // is a control that cannot do anything, offered at the one moment it is useless.
            if model.hasReadFileTree, !model.fileTree.isEmpty {
                InspectorFilterField(query: $query, onEscape: escape, onReturn: enterTree)
                Hairline()
            }

            ScrollViewReader { proxy in
                tree
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The row an arrow key moved to comes into view, which is the other half of
                    // the key. Only while the tree holds the keyboard, so a listing that arrives
                    // while the reader is elsewhere does not move what they are looking at.
                    .onChange(of: selection) { _, path in
                        guard hasKeyboard, let path else { return }
                        proxy.scrollTo(path)
                    }
            }
            // Arrows, left and right through the folders, Home and End, type-select, Return, and
            // the space bar Quick Look that used to be reachable only with the pointer. See
            // `ListKeyboardHost`. Around the tree rather than around the whole tab, so the ring it
            // draws says the TREE has the keyboard at the moment the field above it does not.
            .listKeyboard(
                hasKeyboard: $hasKeyboard,
                previewing: previewURL,
                armToken: keyboardArm,
                onKey: handle
            )
        }
        .task(id: LoadID(workspaceID: model.workspace.id, workspacePath: model.workspace.path)) {
            // Nothing is thrown away first. A workspace whose listing has already been read draws
            // it on the frame it arrives on, and this returns without a subprocess.
            expanded = []
            // The filter goes with the workspace it was typed at. Carrying it across would show
            // the next worktree already narrowed by a word nobody typed at it.
            query = ""
            await model.refreshFileTree()
        }
        .onChange(of: model.fileTree, initial: true) { _, _ in rebuildRows() }
        .onChange(of: query) { _, _ in rebuildRows() }
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
        } else if let filtered, filtered.isEmpty {
            // A blank pane under a field with something in it reads as the tree having broken
            // rather than as the needle having found nothing.
            EmptyStateView(
                glyph: "magnifyingglass",
                title: "No files match",
                message: "Nothing in this worktree matches \(query)."
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
                isExpanded: openFolders.contains(path),
                isChanged: changedPaths.contains(path),
                fullPath: fullPath(path),
                action: { activate(item.node) },
                onOpenTerminal: { FolderTerminalTab.open(folder: fullPath(path), in: model) }
            )
            .equatable()
        }
        .padding(.horizontal, Metrics.spacingSmall)
    }

    // MARK: - What is drawn

    /// The listing the rows come from: the real one, or the narrowed one while a filter is live.
    private var children: [String: [FileTreeNode]] {
        filtered?.children ?? model.fileTree
    }

    /// The folders drawn open, which is the reader's own set until a filter is live and the
    /// filter's while it is. Two sets rather than one, so clearing the field restores rather than
    /// guesses: see `expanded`.
    private var openFolders: Set<String> {
        filtered == nil ? expanded : filterOpen
    }

    // MARK: - Actions

    /// A directory opens or closes, and a file opens in the centre column: as a diff if the agent
    /// touched it, as its own contents if it did not. The tree keeps its own selection for the
    /// highlight and for Quick Look, and a file the agent touched also becomes the changed list's
    /// selection, so the two tabs of this column agree about what is open.
    private func activate(_ node: FileTreeNode) {
        keyboardArm += 1

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
    ///
    /// The filter is folded in here rather than anywhere near `body`, for the same reason the rows
    /// are: this runs when the listing or the needle changes, and `body` runs on every layout pass.
    private func rebuildRows() {
        let outcome = FileTreeFilter.apply(
            to: model.fileTree, needle: FileNeedle.canonical(query)
        )
        filtered = outcome
        // Taken from the outcome rather than merged with what was open a keystroke ago. Every call
        // here is a new needle or a new listing, and a folder the reader collapsed under the
        // previous needle is not an opinion about this one.
        filterOpen = outcome?.open ?? []
        adopt(FileTreeRowItem.flatten(
            children: outcome?.children ?? model.fileTree,
            expanded: outcome?.open ?? expanded
        ))
    }

    private func adopt(_ items: [FileTreeRowItem]) {
        rows = items
        rowTitles = items.map(\.node.name)

        // A folder that closed under the keyboard takes its children off the screen, and a cursor
        // naming a row that is not drawn any more would leave every key after it measured from
        // nothing. A needle that no longer matches the selected file does the same thing.
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
    ///
    /// **Type-select is still here and is not narrowed by the filter field above.** The two never
    /// run at once: this is reached only while `ListKeyboardHost` is first responder, and the
    /// field is a first responder of its own. So typing at the tree jumps to a row as it always
    /// has, and typing at the field filters; which of the two is happening is said by the focus
    /// ring, which is drawn around the tree alone.
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

    /// The tree as its keyboard sees it. `openFolders` is what the reader opened, or what the
    /// filter opened for them, so a directory nobody has touched is closed, which is the opposite
    /// default from the changed file tree and right for a listing this size.
    private var treeShape: [TreeRow] {
        let open = openFolders
        return rows.map {
            TreeRow(
                depth: $0.depth,
                isDirectory: $0.node.isDirectory,
                isExpanded: open.contains($0.node.path)
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
        var opened = openFolders
        if opened.contains(node.path) {
            opened.remove(node.path)
        } else {
            opened.insert(node.path)
        }

        let items = FileTreeRowItem.flatten(children: children, expanded: opened)
        let motion = TreeDisclosureMotion.rows(
            changing: abs(items.count - rows.count), reduceMotion: reduceMotion
        )

        // Outside the transaction, so the highlight lands with the click rather than fading in
        // behind the rows.
        selection = node.path

        withAnimation(motion.animation) {
            // Under a filter this writes the filter's set, so closing a folder the needle opened
            // holds until the needle changes and costs the reader nothing once the field is clear.
            if filtered == nil {
                expanded = opened
            } else {
                filterOpen = opened
            }
            adopt(items)
        }
    }

    // MARK: - The filter field

    /// Escape in the filter field, in the two steps a Mac search field has: the first clears what
    /// was typed, and with nothing left to clear the second hands the keyboard to the tree the
    /// field was narrowing. Clearing puts every folder back where the reader had it, which is the
    /// whole of why `expanded` and `filterOpen` are two sets: see `FileTreeFilter`.
    private func escape() {
        guard query.isEmpty else {
            query = ""
            return
        }
        enterTree()
    }

    /// Return in the filter field, and the second Escape: the keyboard moves to the tree.
    ///
    /// On the first file the filter found rather than on the folder above it, because the folders
    /// on screen under a live needle are mostly there to hold the answer up rather than because
    /// anybody asked for them. With something already selected the selection is left alone: it
    /// survived `adopt`, so it is still a row the needle matches.
    private func enterTree() {
        if selection == nil,
           let first = rows.first(where: { !$0.node.isDirectory }) ?? rows.first {
            selection = first.node.path
        }
        keyboardArm += 1
    }

    private func fullPath(_ relative: String) -> String {
        (model.workspace.path as NSString).appendingPathComponent(relative)
    }

}
