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
/// Collapsing reads the repo's stored `collapsed` flag directly: when it is set the section hands
/// the list no rows at all. The control that drives it is the header's own leading mark. See
/// `body` for why it is not `Section(isExpanded:)`, which the list answers with a second
/// disclosure control of its own.
struct RepoSection: View {
    var repo: Repo
    var rows: [Workspace]
    /// Only used to say why the section is empty, which is a different sentence when a filter is
    /// hiding rows than when the project has none.
    var isFiltered: Bool
    /// Whether any of this project's workspaces has a finished turn nobody has read.
    ///
    /// Passed in rather than derived from `rows`, because `rows` is what the filter is letting
    /// through. See `SidebarRepoGroup.hasUnreadWork`.
    var hasUnreadWork: Bool
    @Binding var renaming: String?
    /// Raised to the sidebar, which owns the create sheet.
    var onCreateWorkspace: (Repo) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Opens the project settings window from the context menu, the same call the gear makes.
    @Environment(\.openWindow) private var openWindow

    @State private var isRenamingRepo = false
    @State private var repoDraft = ""
    @FocusState private var repoFieldFocused: Bool

    @State private var isConfirmingRemove = false
    /// Lights the `+`. It belongs to this header rather than to a hover id shared across the whole
    /// list, so crossing the pane lights one project at a time.
    @State private var isHeaderHovered = false

    /// A plain `Section`, and the rows themselves are what comes and goes.
    ///
    /// It was a `Section(isExpanded:)`, which is the obvious way to fold a source list section and
    /// is the wrong one here. Handing the list a binding is what makes it offer a collapse control
    /// of its own, and on macOS 26 that control is a chevron pinned to the trailing end of the
    /// header, drawn only while the pointer is over the header. So a hovered project header carried
    /// two disclosure controls: this section's own chevron in its gutter at the leading edge, and
    /// the list's, past the gear and the `+`, saying the same thing a second time.
    ///
    /// Two things went with the binding, both measured rather than guessed. The list's own fold
    /// animation: rows now appear and disappear rather than sliding. And the left arrow key on the
    /// header row, which the outline used to answer by folding the project. Neither is worth the
    /// duplicate control. The arrow in particular was only ever reachable by clicking the header
    /// first, and a click on the header is a click one gutter away from the chevron that does the
    /// same thing; arrowing through the rows never reached it, because the header carries no tag
    /// and so is never in the selection. Everything else survived: `repo.collapsed` in the database
    /// was always the source of truth rather than the list's, so the state still restores across a
    /// relaunch, and the header row is still an `AXOutlineRow` reporting `AXDisclosing` with the
    /// workspace rows as its disclosed rows.
    var body: some View {
        Section {
            if !repo.collapsed {
                ForEach(rows) { workspace in
                    row(workspace)
                }
                if rows.isEmpty {
                    emptyNotice
                }
            }
        } header: {
            header
        }
    }

    // MARK: - Header

    /// The confirmations hang off the header rather than off the `Section`, because a section is
    /// a layout instruction to the list rather than a view that can present anything. That also
    /// keeps them anchored to the project they are about, which is where the menus that trigger
    /// them live.
    private var header: some View {
        HStack(spacing: Metrics.spacing) {
            disclosure

            RepoIcon(repo: repo)

            if isRenamingRepo {
                TextField("Project name", text: $repoDraft)
                    .textFieldStyle(.plain)
                    .font(Typo.title)
                    .focused($repoFieldFocused)
                    .onSubmit(commitRepoRename)
                    .onExitCommand { isRenamingRepo = false }
            } else {
                name
            }

            Spacer(minLength: Metrics.spacingSmall)

            // The gear is drawn only under the pointer. It used to be present at rest and merely
            // lit on hover, on the argument that Finder's own sidebar headers do that with Show
            // and Hide; the owner looked at the result and asked for it to be revealed instead.
            // A project's settings are the rarest thing anyone does to a project, and a gear on
            // every header is a column of them down a pane whose job is to name the work.
            //
            // Faded rather than built and torn down: the button stays in the hierarchy at every
            // moment and only its opacity moves, so nothing about the header's layout depends on
            // where the pointer is, the row cannot reflow as the pointer crosses it, and the view
            // keeps one identity rather than being a different view on each side of the hover.
            // The fade is what keeps a pointer travelling down a full pane from reading as a
            // column of gears flickering on and off, and it goes when Reduce Motion is on, which
            // leaves the reveal instant rather than animated.
            //
            // The `+` beside it stays present at rest. It is the one thing anyone does to a
            // project often enough to look for, and a trailing edge that empties completely on
            // every header would leave nothing to aim at.
            //
            // Nothing is lost with the pointer away: Project settings is on this header's own
            // context menu, and in File as Project Settings with Command Shift comma.
            RepoSettingsButton(repo: repo, isHighlighted: isHeaderHovered)
                .opacity(isHeaderHovered ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHeaderHovered
                )

            // Boxed to the tile's size at the other end of the row, so the header is bracketed by
            // two marks of one size rather than by an icon and a speck. The padding is the click
            // target, and it is inside the label because a button's hit area is its label, which
            // is why the `contentShape` outside the button widened nothing.
            Button {
                onCreateWorkspace(repo)
            } label: {
                Label("New workspace in \(repo.name)", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    // One rung down from the project's name. It was set at the name's size to
                    // bracket the header with two marks of the tile's size, but the leading end of
                    // the header now carries two marks of its own, and a `+` that matches the
                    // heading is the loudest thing in a column it is the least important part of.
                    .font(Typo.label)
                    .frame(
                        width: Metrics.headerButton.width,
                        height: Metrics.headerButton.height
                    )
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
        // A section header is given more room at its trailing edge than a plain row is, so the
        // `+` was drawn about eight points further right than the diff counts on the rows under
        // it and than the add button on the Projects heading, which left the pane's trailing edge
        // ragged. Eight points of padding puts all three in one column. Nothing here changes the
        // row's height: the header's own drawing band is 19 points and this is horizontal.
        .padding(.trailing, Metrics.spacingWide)
        .contentShape(Rectangle())
        .onHoverChange { isHeaderHovered = $0 }
        .contextMenu {
            Button("New workspace") { onCreateWorkspace(repo) }
            Button(repo.collapsed ? "Show workspaces" : "Hide workspaces") {
                Task { await app.toggleCollapsed(repo) }
            }
            Button("Rename", action: beginRepoRename)
            // The route to this project's settings that needs no pointer on the gear, which is
            // drawn only while the pointer is on the header. File's own Project Settings item
            // opens the selected workspace's project; this one opens the project it was raised
            // from, which is not always the same thing.
            Button("Project settings…") {
                openWindow(id: RepoSettingsWindow.id, value: repo.id)
            }
            Button("Reveal in Finder") { Reveal.inFinder(repo.path) }
            Divider()
            Button("Remove project", role: .destructive) { isConfirmingRemove = true }
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

    /// The project's name, one weight heavier while something inside it is waiting to be read.
    ///
    /// Weight, because that is what a workspace row already does for the same fact: an unread row
    /// steps from regular to medium and takes the accent dot. The header steps from the heading's
    /// own semibold to bold and takes nothing else, so the two read as one signal at two ranks
    /// rather than as two different marks. There is not much room above semibold at 13 points, and
    /// that is the point: the projects with work waiting should stand out from the ones without,
    /// not shout at the rows underneath them.
    ///
    /// It earns its keep on a COLLAPSED project, where the rows that carry the dots are not on
    /// screen at all and the header is the only thing left to say so.
    ///
    /// The weight is invisible to VoiceOver, so the same fact is said in words as the heading's
    /// value. The dot on the row does the same through `WorkspaceRow`'s status description.
    /// `Typo.title` with one more step of weight on it, and nothing else changed. Not a rung of
    /// the scale, because it is not a size: it is the same rung saying one more thing.
    private static let unreadTitle = ScaledFont(.headline, weight: .heavy)

    @ViewBuilder
    private var name: some View {
        // A source list section header is usually set below its rows, which is right when the
        // header names a category ("Favorites", "Locations") and the rows are the things. Here the
        // header names a thing: a project, with its own icon, its own menu and its own colour, and
        // the rows are what is inside it. Mail's account headers and Xcode's project group are the
        // closer precedent, and both sit at reading size in the heading weight. `Typo.title` is
        // that, and it is what the same project name is already set in on Home, so the two agree.
        //
        // The rows below are `Typo.body`, one weight lighter and one shade quieter, so the pair
        // reads as a heading and its contents rather than as two ranks of similar grey text.
        // The weight is part of the rung rather than a `fontWeight` laid over it. `Typo.title` is
        // `.headline`, which carries its own weight inside the `Font` it resolves to, and a
        // `fontWeight` outside that resolves to nothing at all: captured both ways, the two names
        // were identical to the pixel.
        let label = Text(repo.name)
            .font(hasUnreadWork ? Self.unreadTitle : Typo.title)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)

        if hasUnreadWork {
            label
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue("Has unread work")
        } else {
            label.accessibilityAddTraits(.isHeader)
        }
    }

    /// The control that folds the project away, in a gutter of its own at the leading edge.
    ///
    /// It used to share the tile's box and appear only under the pointer, which spent no width on
    /// a chevron that is idle almost all the time. The cost was that it took the project's mark
    /// away to do it: the one thing in the header worth scanning vanished exactly when you looked
    /// at the header. A gutter costs eleven points and gives the tile back for good.
    ///
    /// Eleven points is also the step the workspace rows are indented by, which is what makes a
    /// project read as containing its rows: the chevron sits alone at the pane's leading edge, the
    /// project's tile starts one gutter in, and a row's status mark starts on that same column
    /// rather than to the left of it. See `SidebarMetrics.rowIndent`, which is this number.
    ///
    /// The chevron is the smallest mark in the pane on purpose. It is furniture: it says the thing
    /// beside it opens, and then it should get out of the way of everything that has something to
    /// say. Measured off the reference render at roughly five points across in a secondary ink.
    ///
    /// This is the only disclosure control the header has, and keeping it that way is what cost the
    /// section its `isExpanded` binding. A comment here used to say the list drew no control of
    /// its own, on the strength of a capture. The capture was real and the reading of it was not:
    /// every sidebar shot in that session came out of a launch, wait, capture, exit run with no
    /// pointer anywhere near the window, and the list's control is drawn only under the pointer.
    /// The tell is in the picture: in a genuinely hovered header the `+` sits on its hover plate.
    /// In those shots it did not. Hover here needs a real pointer, moved with real events, over
    /// the header's own rect; it does NOT need the app to be frontmost, which was measured both
    /// ways.
    ///
    /// A real `Button`, present at rest, so Full Keyboard Access can reach it and VoiceOver reads
    /// it with its expanded state as a value.
    private var disclosure: some View {
        Button {
            Task { await app.toggleCollapsed(repo) }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: SidebarMetrics.caretSize, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .rotationEffect(.degrees(repo.collapsed ? 0 : 90))
                .frame(width: SidebarMetrics.caretGutter, height: Metrics.repoIcon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The turn is movement, so it goes when Reduce Motion is on. Without it the chevron still
        // changes direction, it just arrives there rather than travelling.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: repo.collapsed)
        .accessibilityLabel(repo.collapsed ? "Show workspaces in \(repo.name)" : "Hide workspaces in \(repo.name)")
        .accessibilityValue(repo.collapsed ? "Collapsed" : "Expanded")
        .help(repo.collapsed ? "Show workspaces" : "Hide workspaces")
    }

    // MARK: - Rows

    /// What stands where the workspaces would be when there are none to draw.
    ///
    /// A `Label` with nothing in its icon, so the sentence starts on the same column a workspace's
    /// name starts on rather than on a column of its own. It is a sentence about the project, not
    /// an item in the list, so it takes the name's column and not the mark's.
    private var emptyNotice: some View {
        Label {
            Text(isFiltered ? "Nothing matches the filter" : "No workspaces yet")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        } icon: {
            Color.clear
        }
        // The same layout the rows it stands in for use, so the sentence starts on the name's
        // column rather than on a column of its own.
        .labelStyle(SidebarRowLabelStyle())
        .padding(.leading, SidebarMetrics.rowIndent)
    }

    private func row(_ workspace: Workspace) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isRunning: app.isRunning(workspace),
            renaming: $renaming,
            onArchive: confirmRowArchive
        )
        .padding(.leading, SidebarMetrics.rowIndent)
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
            // Straight through, with no dialog of its own. Whether this needs confirming is not
            // something this menu can know: it depends on what is uncommitted, what is running and
            // what GitHub says about the branch, and `AppModel.archive` is where all three come
            // together. Asking here as well meant a sheet on every archive, including the routine
            // one, which is exactly how a confirmation stops being read.
            //
            // Whether the branch goes too is the repository's setting, rather than a question
            // asked every time about a workspace that is usually finished with.
            //
            // The row's own archive button does ask every time, and that is not a disagreement
            // with this. See `confirmRowArchive` for why an entry point that appears under the
            // pointer is the one that should.
            Button("Archive", role: .destructive) { archive(workspace) }
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

    private func archive(_ workspace: Workspace) {
        Task { await app.archive(workspace) }
    }

    /// What the row's archive button does instead of archiving.
    ///
    /// This entry point asks EVERY time, including when nothing is at stake and `AppModel.archive`
    /// would have archived silently. That looks like it contradicts the conditional path, and it
    /// does not: the conditional path is right about the context menu and the keyboard, where you
    /// have already said what you mean by opening a menu or pressing a shortcut, and a
    /// confirmation with nothing to warn about is exactly how a confirmation stops being read.
    /// A hover button is a different thing. It appears under the pointer, unbidden, a few points
    /// from the row you meant to click, which makes it the easiest way in the app to archive
    /// something by accident. So the asking is a property of THIS ENTRY POINT rather than of the
    /// archive: everything else still archives silently when there is nothing to lose.
    ///
    /// It used to ask with a compact dialog of its own, and answering yes could then raise the
    /// model's larger one, so a workspace with real work in it produced two dialogs of different
    /// shapes for a single decision. The asking is still a property of THIS ENTRY POINT, but it
    /// is now said as an argument, and the one dialog that appears is the one that knows what is
    /// at stake. See `AppModel.archive(_:deleteBranch:alwaysConfirm:)`.
    private func confirmRowArchive(_ workspace: Workspace) {
        Task { await app.archive(workspace, alwaysConfirm: true) }
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
        Clipboard.copy(text)
    }
}
