import SwiftUI
import AppKit
import BloomCore

/// One project, as a row of the source list that its workspaces hang under.
///
/// It used to be a `Section` with those workspaces as its content, which is the obvious shape for
/// a source list and is the one shape that cannot be reordered: `onMove` on a `ForEach` of
/// `Section`s does not crash and does not work either, because a section header is not a row the
/// outline will pick up, and there is no second `onMove` that reaches one. The pane is now a
/// single flat run of rows with one `onMove` over it (see `SidebarView`), so this draws a row like
/// any other and a project is reordered by dragging it.
///
/// This row owns everything that surrounds a project: its menu, its rename, the confirmation that
/// removes it. `SidebarWorkspaceRow` owns the same for a workspace, and `WorkspaceRow` stays a
/// pure drawing of one. Splitting it this way keeps the row cheap to redraw, which matters because
/// a running agent updates its diff stat every few seconds.
///
/// Collapsing reads the repo's stored `collapsed` flag directly: while it is set the workspace
/// rows are simply not in the run. The control that drives it is this row's own leading mark, and
/// it is the only disclosure control here. Handing a list an `isExpanded` binding is what makes it
/// draw a second one, and on macOS 26 that one is a chevron pinned to the trailing end of the
/// header under the pointer, which landed past the gear and the `+` and said what the leading
/// chevron already said.
struct RepoHeaderRow: View {
    var repo: Repo
    /// Whether any of this project's workspaces has a finished turn nobody has read.
    ///
    /// Passed in rather than derived from the rows, because the rows are what the filter is
    /// letting through. See `SidebarRepoGroup.hasUnreadWork`.
    var hasUnreadWork: Bool
    /// How many workspace rows are drawn under this project, which is what the filter is letting
    /// through. Said out loud rather than drawn: see `name`.
    var workspaceCount: Int
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
    /// Lights the `+`. It belongs to this row rather than to a hover id shared across the whole
    /// list, so crossing the pane lights one project at a time.
    @State private var isHeaderHovered = false

    /// A row, not a section, and one that keeps a section's rhythm.
    ///
    /// A section header was given 13 points of spacing above a drawing band of 19, which together
    /// are the 32 point pitch every row in this list is drawn on. A plain row is handed the whole
    /// 32 and centres its content in it, so without the lead a project would sit hard against the
    /// last workspace of the project before it and the pane would lose the one gap that says a new
    /// project starts here. The padding puts that gap back INSIDE the row's own 32 points rather
    /// than on top of them, so the pitch is unchanged and nothing below moves.
    /// There is no trailing padding here any more, and that is the other half of the same change.
    ///
    /// A section header was given more room at its trailing edge than a plain row is, so the `+`
    /// used to be drawn about eight points right of everything below it and eight points of
    /// padding was what pulled it back. A plain row is handed the same insets as the rows under
    /// it, so that padding had nothing left to correct and simply moved the `+` fourteen points
    /// the other way. Measured on captures of both, at the pixel: the same glyph's trailing ink
    /// stood at 482 as a section header with the padding, at 454 as a plain row with it, and at
    /// 470 as a plain row without it, where the Projects heading's own button, which is a plain
    /// row and carries the same frame, stands at 479. What is left is the difference between two
    /// glyphs inside one frame, not a difference in the column.
    var body: some View {
        header.padding(.top, SidebarMetrics.headerLead)
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

    /// The project's name with what is under it, for VoiceOver only.
    private var countedName: String {
        workspaceCount == 1
            ? "\(repo.name), 1 workspace"
            : "\(repo.name), \(workspaceCount) workspaces"
    }

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

        // The heading says what the outline no longer does.
        //
        // A `Section` header was an `AXOutlineRow` reporting `AXDisclosing`, with the rows under
        // it as its disclosed rows and those rows one disclosure level below it, and that is the
        // whole of how a screen reader hears a project CONTAINING its workspaces. The flat run has
        // no such relationship to report: every row in the pane is at level zero.
        //
        // It cannot be put back by hand, and that was measured rather than assumed. SwiftUI has no
        // modifier for it: `AccessibilityTraits` on macOS 26 is seventeen traits and not one of
        // them is an outline row or a disclosure. Neither is it reachable through AppKit. A zero
        // sized `NSViewRepresentable` in a row's own content does find the `NSTableRowView` the
        // list drew that row into, and setting the subrole, the disclosure level, the disclosed
        // flag, a label and even a role description on it changes NOTHING in the tree the app
        // vends: dumped through `AXUIElementCreateApplication` before and after, every row still
        // answered exactly what SwiftUI decided. Those `AXRow` elements are SwiftUI's own, and the
        // row view is not what a screen reader is talking to.
        //
        // So the fact is carried in words, which is the one channel SwiftUI does hand over. This
        // heading says how many rows the project has, its chevron says whether they are showing,
        // and each row says which project it is in as accessibility custom content. The count is
        // what the filter is letting through, because that is what is actually under the heading.
        //
        // Whether the project is open is on the chevron beside this, as that button's own value,
        // and the rows themselves each name the project they are in.
        let counted = label.accessibilityLabel(Text(countedName))

        if hasUnreadWork {
            counted
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue("Has unread work")
        } else {
            counted.accessibilityAddTraits(.isHeader)
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

    // MARK: - Actions

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
}
