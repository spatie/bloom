import SwiftUI
import BloomCore

/// One workspace in the source list, with everything that surrounds it.
///
/// The drawing is `WorkspaceRow`'s and stays a pure function of the workspace, which is what keeps
/// it cheap to redraw while a running agent rewrites its diff stat every few seconds. What is here
/// is what the list is told about the row: where it sits, what it is tagged with, what its menu
/// offers, and the archive that menu and the row's own button both go through.
///
/// It was `RepoSection.row(_:)` and moved out of it whole when the pane was flattened into one run
/// of rows. Nothing about a workspace row changed in that move: it is drawn, indented, tagged and
/// right clicked exactly as it was.
struct SidebarWorkspaceRow: View {
    var workspace: Workspace
    /// Which rows have only just been added to the list, so they fade in rather than appear.
    /// Handed down from `SidebarView`, which owns the one tracker the whole pane shares: a
    /// workspace can move between projects, and two trackers would each read that as an arrival
    /// and a departure of their own.
    var arrival: RowArrival<WorkspaceID>
    /// The project this row is under, for the one thing the flat pane cannot say structurally.
    /// See `body`, and `RepoHeaderRow.name` for why this is words rather than an outline level.
    var projectName: String
    @Binding var renaming: WorkspaceID?

    @Environment(AppModel.self) private var app

    /// Where this row is on screen, for the card that opens beside it. Held rather than reported:
    /// see `HoverCardAnchor`.
    @State private var anchor = HoverCardAnchor()

    var body: some View {
        WorkspaceRow(
            workspace: workspace,
            isRunning: app.isRunning(workspace),
            isAwaitingPermission: app.isAwaitingPermission(workspace),
            renaming: $renaming,
            onArchive: confirmRowArchive
        )
        // Innermost, on the drawing alone. Everything below this line is what the list is told
        // about the row, and a workspace that is fading in is still selectable, draggable and
        // right clickable throughout: it is a row that is fully there and briefly not drawn.
        .arrivingRow(arrival.isArriving(workspace.id))
        .padding(.leading, SidebarMetrics.rowIndent)
        // Which project this row is under.
        //
        // A `Section` said it structurally: the row was an `AXOutlineRow` one disclosure level
        // below its project's, and a screen reader read that level out. The flat run the drag
        // needs has no levels, and the outline's own attributes are not ours to set, which was
        // measured rather than assumed: see `RepoHeaderRow.name`. So the fact is carried as custom
        // content instead, which is the API meant for exactly this: one more thing about a row,
        // said after the row's own label, in the order it is given.
        //
        // High importance, because it is not an extra. A pane of thirty workspace rows with no
        // nesting left in it is unreadable without knowing which project each row belongs to, and
        // content that has to be asked for is content most people never hear.
        .accessibilityCustomContent(Text("Project"), Text(projectName), importance: .high)
        // The card that opens beside the row, and the handle that says where the row is.
        //
        // Here rather than in `WorkspaceRow`, and this is the same line the type's own note draws:
        // `WorkspaceRow` is the drawing and stays a pure function of what it is handed, while what
        // the LIST is told about a row lives here. A card that opens over the whole window on a
        // hover is squarely the second kind, and it needs the two things only this side has
        // anyway, which are the model that knows whether an agent is running and the poll that
        // knows what GitHub said.
        //
        // Its own `.onHover`, not the one inside `WorkspaceRow`. Two hover trackers on nested
        // views both fire, and joining them would mean handing the drawing a callback it has no
        // use for. Nothing is drawn from this one, so nothing redraws when it changes.
        .background { HoverCardAnchorReader(anchor: anchor) }
        .onHoverChange { inside in
            if inside {
                WorkspaceHoverCardPresenter.shared.pointerEntered(
                    .workspaceRow(workspace.id),
                    card: hoverCard,
                    anchor: { anchor.screenFrame }
                )
            } else {
                WorkspaceHoverCardPresenter.shared.pointerExited(.workspaceRow(workspace.id))
            }
        }
        // A row that leaves the pane while its card is up: archived from the menu bar, filtered
        // out, or its project folded. The pointer never leaves, so no exit ever arrives.
        .onDisappear {
            WorkspaceHoverCardPresenter.shared.pointerExited(.workspaceRow(workspace.id))
        }
        // Every item in it is `WorkspaceMenuItems`, which Home's rows draw from as well. It used
        // to be a copy of the same six buttons written out here, with a note on the other copy
        // saying what to extract when the two were merged; adding to both was what forced it.
        //
        // The row's own hover ellipsis draws the same view, so a press and a right click on one
        // row cannot come up with different menus. See `WorkspaceRow.moreMenu`.
        .contextMenu { WorkspaceMenuItems(workspace: workspace) { renaming = $0 } }
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

    /// What the card says, built at the moment it opens rather than on every redraw.
    ///
    /// **Nothing in here fetches.** `isRunning` is the model's own answer about a turn already in
    /// progress and the pull request is whatever `WorkspacePullRequests` last polled, which is the
    /// same two facts the row's status mark is already drawn from. A hover that started a `gh`
    /// call would put a subprocess behind moving the pointer down a list of thirty rows.
    ///
    /// It returns nil for a row being renamed. The field owns the row while it is open, and a
    /// card over the window showing the name being replaced is a card about a fact that is in the
    /// middle of changing.
    private func hoverCard() -> WorkspaceHoverCard? {
        guard renaming != workspace.id else { return nil }
        return WorkspaceHoverCard.make(
            workspace: workspace,
            isRunning: app.isRunning(workspace),
            isAwaitingPermission: app.isAwaitingPermission(workspace),
            pullRequest: WorkspacePullRequests.shared.pullRequest(for: workspace.id)
        )
    }
}

/// What stands where a project's workspaces would be when there are none to draw.
///
/// A `Label` with nothing in its icon, so the sentence starts on the same column a workspace's
/// name starts on rather than on a column of its own. It is a sentence about the project, not an
/// item in the list, so it takes the name's column and not the mark's.
///
/// It is a row in the run like any other now that the pane is flat, which is why it refuses both
/// selection and the drag: a sentence is not something to pick up, and `SidebarReorder` refuses it
/// a second time in case the outline offers it anyway.
struct SidebarEmptyNoticeRow: View {
    /// Only used to say WHY there is nothing here, which is a different sentence when a filter is
    /// hiding rows than when the project has none.
    var isFiltered: Bool
    /// Starts one. Absent when a filter is what is hiding the rows, because the way out of that is
    /// to change the filter and a project with workspaces does not need a button offering more.
    var onCreate: (@MainActor () -> Void)?

    var body: some View {
        Label {
            // The sentence, and then the way out of it. Every other empty state in the app carries
            // one: the sidebar's "No projects yet", Home's, the create sheet's. This one said "No
            // workspaces yet" and stopped, and the `+` that fixes it is on the header above and
            // only appears once the pointer is on that header.
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(isFiltered ? "Nothing matches the filter" : "No workspaces yet")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)

                // **A control, not a link.** It was `linkButton`, which is the style for a
                // sentence with an address in it, and in a sidebar it came out as a line of blue
                // web text under a grey one: the owner's word for it was fugly, and he is right.
                // Nothing else in this column is underlined-blue-adjacent, and what this does is
                // open a sheet rather than go somewhere.
                //
                // It stays rather than being deleted, because the `+` that does the same thing is
                // on the header above and only appears once the pointer is on that header. An
                // empty project with no visible way out of being empty is the reason this was
                // added.
                if !isFiltered, let onCreate {
                    Button(action: onCreate) {
                        Label("New workspace", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                            .font(Typo.caption)
                    }
                    .buttonStyle(.accessoryBar)
                    .tint(Palette.accent)
                    .controlSize(.small)
                }
            }
        } icon: {
            Color.clear
        }
        // The same layout the rows it stands in for use, so the sentence starts on the name's
        // column rather than on a column of its own.
        .labelStyle(SidebarRowLabelStyle())
        .padding(.leading, SidebarMetrics.rowIndent)
    }
}
