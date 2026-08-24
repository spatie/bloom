import SwiftUI
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
/// rows are simply not in the run. The control that drives it is this row's own leading chevron,
/// and it is the only disclosure control here. Handing a list an `isExpanded` binding is what
/// makes it draw a second one, and on macOS 26 that one is a chevron pinned to the trailing end of
/// the header under the pointer, which landed past the `+` and said what the leading chevron
/// already said.
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
    /// Lights the `+` and swaps the project's mark for its settings gear. It belongs to this row
    /// rather than to a hover id shared across the whole list, so crossing the pane lights one
    /// project at a time.
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
        header
            .padding(.top, SidebarMetrics.headerLead)
            // A hidden project the owner has asked to see is drawn exactly where it would be, at
            // exactly the size it would be, in less ink. Nothing else: no badge, no italic, no
            // section of its own. The list has one job at a glance, which is to be scannable, and
            // a project that is only here because a switch is on should be the quietest thing in
            // the column rather than the most decorated.
            //
            // On the whole header rather than on the icon and the name separately, because it is
            // one dimming and two opacities that have to agree are two opacities that will not.
            // The `+` and the settings gear are inside it and dim with it, which is right: they
            // are furniture of a row that is being played down, and they are drawn only under the
            // pointer anyway.
            //
            // The workspace rows underneath are NOT dimmed. They are real work, running or
            // waiting to be read, and greying out a turn that has finished because its project is
            // tidied away would be the one thing hiding is not allowed to do.
            .opacity(repo.hidden ? SidebarMetrics.hiddenDim : 1)
    }

    // MARK: - Header

    /// The confirmations hang off the header rather than off the `Section`, because a section is
    /// a layout instruction to the list rather than a view that can present anything. That also
    /// keeps them anchored to the project they are about, which is where the menus that trigger
    /// them live.
    private var header: some View {
        HStack(spacing: Metrics.spacing) {
            disclosure

            mark

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
        // Every item and the reasoning for the shape is `ProjectMenuItems`, beside the workspace
        // row's own menu, so a menu can be photographed rather than only read.
        .contextMenu {
            ProjectMenuItems(
                repo: repo,
                onCreateWorkspace: onCreateWorkspace,
                onRename: beginRepoRename,
                onRemove: { isConfirmingRemove = true }
            )
        }
        .confirmationDialog(
            removal.title,
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button(removal.confirmLabel, role: .destructive, action: removeRepo)
            Button(removal.cancelLabel, role: .cancel) {}
        } message: {
            Text(removal.message)
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
    ///
    /// A hidden project says so here, because the only other thing that says it is an opacity and
    /// a screen reader cannot see one. Same reasoning as the unread weight two properties down.
    private var countedName: String {
        let counted = workspaceCount == 1
            ? "\(repo.name), 1 workspace"
            : "\(repo.name), \(workspaceCount) workspaces"
        return repo.hidden ? counted + ", hidden" : counted
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

    /// The project's mark, and the settings gear that takes its place under the pointer.
    ///
    /// The gear used to sit at the trailing edge beside the `+`, revealed on hover in the same
    /// way. The owner asked for it on the leading side, before the name, and still only under the
    /// pointer. That is a harder place to put a control than it sounds, because the leading end of
    /// this header is already two columns wide and both of them are load bearing: the chevron's
    /// gutter is the step every workspace row underneath is indented by, and the tile starts the
    /// column a workspace's status mark is drawn in. A gear inserted between them, or given a
    /// reserved slot of its own, moves one of those columns for good, and the rows below with it.
    /// A gear that appears and pushes the name aside reflows the row every time the pointer
    /// crosses it, which is worse again.
    ///
    /// So it takes the tile's own box: sixteen points, the same box whether the pointer is there
    /// or not, with the tile and the gear stacked in it and only their opacity moving. Nothing in
    /// the header can move, because nothing about the layout depends on the hover, and the
    /// alignment measured this morning is untouched: the chevron is where it was, the tile's
    /// column is where it was, and the name starts where it started.
    ///
    /// The cost is honest and worth saying out loud, because this repeats a shape that was tried
    /// and rejected here once. The chevron used to share the tile's box and the tile vanished to
    /// make room for it, which took the one thing worth scanning out of the header exactly when
    /// you looked at it, and the gutter was bought to get the tile back. The difference is what
    /// the box is traded FOR. A chevron is furniture, and losing a project's mark for it buys
    /// nothing; a gear is the control that was asked for, it is only ever hidden on the one row
    /// the pointer is on, and the name it stands beside is still naming the project.
    ///
    /// The chevron is deliberately not the slot. It is the only way to fold a project with a
    /// mouse, and a gear that covered it would take that away for as long as the pointer was on
    /// the row.
    ///
    /// The fade goes when Reduce Motion is on, which leaves the swap instant rather than animated,
    /// matching the archive button on a workspace row and the `+` beside this one.
    private var mark: some View {
        ZStack {
            RepoIcon(repo: repo)
                .opacity(isHeaderHovered ? 0 : 1)

            settingsButton
                .opacity(isHeaderHovered ? 1 : 0)
                // An invisible button still takes clicks, and this one sits on top of the row's
                // own mark. The pointer has to be on the header for it to be drawn at all, so
                // this costs nothing real and stops a resting header eating a click on its tile.
                .allowsHitTesting(isHeaderHovered)
        }
        .frame(width: Metrics.repoIcon, height: Metrics.repoIcon)
        .animation(reduceMotion ? nil : Motion.hover, value: isHeaderHovered)
    }

    /// The gear itself.
    ///
    /// Built here rather than reusing `RepoSettingsButton`, which is boxed to
    /// `Metrics.headerButton` and carries a hover plate: both were right at the trailing edge and
    /// neither survives the move. A 24 point box in a 16 point column would hang four points over
    /// the chevron and four over the name, and a rounded plate drawn in the tile's own column
    /// would read as a second tile. It opens the window through the same call the menu item does.
    ///
    /// Nothing is lost with the pointer away, and that matters more here than it did at the
    /// trailing edge: Project settings… is on this header's own context menu, and File carries
    /// Project Settings at Command Shift comma.
    private var settingsButton: some View {
        Button {
            openWindow(id: RepoSettingsWindow.id, value: repo.id)
        } label: {
            Label("Settings for \(repo.name)", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .font(Typo.label)
                // The tile's box exactly. The click target is the label, because a button's hit
                // area is its label, which is why a `contentShape` outside the button widens
                // nothing.
                .frame(width: Metrics.repoIcon, height: Metrics.repoIcon)
                .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.textPrimary)
        .help("Settings for \(repo.name)")
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
        .animation(reduceMotion ? nil : Motion.pane, value: repo.collapsed)
        .accessibilityLabel(repo.collapsed ? "Show workspaces in \(repo.name)" : "Hide workspaces in \(repo.name)")
        .accessibilityValue(repo.collapsed ? "Collapsed" : "Expanded")
        .help(repo.collapsed ? "Show workspaces" : "Hide workspaces")
    }

    // MARK: - Actions

    /// The one question, asked here and in both settings panes. See `ProjectRemoval`.
    private var removal: Confirmation {
        ProjectRemoval.confirmation(
            for: repo, workspaces: app.workspaces.filter { $0.repoID == repo.id }
        )
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
}
