import Foundation
import Testing
@testable import BloomCore

/// What a drag inside one project's rows writes to the store.
///
/// The cases that matter are the ones where the order the rows are DRAWN in is not the order they
/// are STORED in: a filter hiding rows between two visible ones, and the pinned rows that sort
/// ahead of everything regardless of `sort_order`. A suite that only moved rows around an
/// unfiltered list of unpinned workspaces would pass against an implementation that wrote the
/// drawn order straight back, which is the implementation this replaced.
@Suite("Sidebar reorder")
struct SidebarReorderTests {
    private func workspace(
        _ id: String, order: Int, pinned: Bool = false
    ) -> Workspace {
        Workspace(
            id: WorkspaceID(id),
            repoID: RepoID("r1"),
            name: id,
            branch: "bloom/\(id)",
            path: "/tmp/\(id)",
            baseBranch: "main",
            sortOrder: order,
            pinned: pinned
        )
    }

    /// Four unpinned rows in the order they are stored in.
    private var four: [Workspace] {
        [
            workspace("a", order: 0),
            workspace("b", order: 1),
            workspace("c", order: 2),
            workspace("d", order: 3),
        ]
    }

    // MARK: - The drawn order

    @Test("Pinned rows are drawn first, then the user's own order")
    func drawnOrder() {
        let rows = [
            workspace("a", order: 0),
            workspace("b", order: 1, pinned: true),
            workspace("c", order: 2),
            workspace("d", order: 3, pinned: true),
        ]
        #expect(SidebarReorder.drawn(rows).map(\.id.rawValue) == ["b", "d", "a", "c"])
    }

    // MARK: - The simple case

    @Test("Moving a row down writes every row it passed")
    func moveDown() {
        let rows = four
        let changes = SidebarReorder.move(visible: rows, all: rows, from: [0], to: 3)
        #expect(changes == [
            SidebarReorder.Change(id: WorkspaceID("b"), sortOrder: 0, pinned: false),
            SidebarReorder.Change(id: WorkspaceID("c"), sortOrder: 1, pinned: false),
            SidebarReorder.Change(id: WorkspaceID("a"), sortOrder: 2, pinned: false),
        ])
    }

    @Test("Moving a row up writes every row it passed")
    func moveUp() {
        let rows = four
        let changes = SidebarReorder.move(visible: rows, all: rows, from: [3], to: 1)
        #expect(changes == [
            SidebarReorder.Change(id: WorkspaceID("d"), sortOrder: 1, pinned: false),
            SidebarReorder.Change(id: WorkspaceID("b"), sortOrder: 2, pinned: false),
            SidebarReorder.Change(id: WorkspaceID("c"), sortOrder: 3, pinned: false),
        ])
    }

    @Test("A drop that changes nothing writes nothing")
    func noMove() {
        let rows = four
        #expect(SidebarReorder.move(visible: rows, all: rows, from: [1], to: 1).isEmpty)
        #expect(SidebarReorder.move(visible: rows, all: rows, from: [1], to: 2).isEmpty)
    }

    @Test("Offsets that are not in the list are refused")
    func outOfRange() {
        let rows = four
        #expect(SidebarReorder.move(visible: rows, all: rows, from: [9], to: 0).isEmpty)
        #expect(SidebarReorder.move(visible: rows, all: [], from: [], to: 0).isEmpty)
    }

    // MARK: - A filter hiding rows

    @Test("A hidden row between two visible ones keeps its place")
    func filteredMoveKeepsHiddenRows() {
        let rows = four
        // The filter is letting a, c and d through. `b` is hidden between a and c.
        let visible = [rows[0], rows[2], rows[3]]
        // Drag `a` below `c`, which the user sees as one row of travel.
        let changes = SidebarReorder.move(visible: visible, all: rows, from: [0], to: 2)
        let order = SidebarReorder.drawn(applied(changes, to: rows)).map(\.id.rawValue)
        // `a` lands after `c`, and `b` is still between where a was and c.
        #expect(order == ["b", "c", "a", "d"])
    }

    @Test("A drop at the top of a filtered pane lands above the first visible row, not the list")
    func filteredDropAtTop() {
        let rows = four
        // Only c and d are visible: a and b are hidden above them.
        let visible = [rows[2], rows[3]]
        let changes = SidebarReorder.move(visible: visible, all: rows, from: [1], to: 0)
        let order = SidebarReorder.drawn(applied(changes, to: rows)).map(\.id.rawValue)
        // `d` goes above `c` and stays below the hidden rows, which is where the user put it.
        #expect(order == ["a", "b", "d", "c"])
    }

    @Test("A project whose only visible rows are the dragged ones changes nothing")
    func nothingToAnchorTo() {
        let rows = four
        let visible = [rows[0]]
        #expect(SidebarReorder.move(visible: visible, all: rows, from: [0], to: 1).isEmpty)
    }

    // MARK: - Pinned rows

    @Test("A row dragged out of the pinned block is unpinned by the drop")
    func draggingOutOfThePinnedBlock() {
        let rows = [
            workspace("a", order: 0, pinned: true),
            workspace("b", order: 1, pinned: true),
            workspace("c", order: 2),
            workspace("d", order: 3),
        ]
        let visible = SidebarReorder.drawn(rows)
        #expect(visible.map(\.id.rawValue) == ["a", "b", "c", "d"])
        // Drag `a` to the bottom.
        let changes = SidebarReorder.move(visible: visible, all: rows, from: [0], to: 4)
        let after = applied(changes, to: rows)
        #expect(SidebarReorder.drawn(after).map(\.id.rawValue) == ["b", "c", "d", "a"])
        #expect(pin(of: "a", in: after) == false)
        // Nothing else changed its pin.
        #expect(pin(of: "b", in: after) == true)
    }

    @Test("A row dragged into the pinned block is pinned by the drop")
    func draggingIntoThePinnedBlock() {
        let rows = [
            workspace("a", order: 0, pinned: true),
            workspace("b", order: 1, pinned: true),
            workspace("c", order: 2),
            workspace("d", order: 3),
        ]
        let visible = SidebarReorder.drawn(rows)
        // Drag `d` to the very top.
        let changes = SidebarReorder.move(visible: visible, all: rows, from: [3], to: 0)
        let after = applied(changes, to: rows)
        #expect(SidebarReorder.drawn(after).map(\.id.rawValue) == ["d", "a", "b", "c"])
        #expect(pin(of: "d", in: after) == true)
    }

    @Test("A row dropped just below the pinned block stays unpinned")
    func droppedUnderThePinnedBlock() {
        let rows = [
            workspace("a", order: 0, pinned: true),
            workspace("b", order: 1),
            workspace("c", order: 2),
        ]
        let visible = SidebarReorder.drawn(rows)
        // Drag `c` to the first unpinned place, which is directly under `a`.
        let changes = SidebarReorder.move(visible: visible, all: rows, from: [2], to: 1)
        let after = applied(changes, to: rows)
        #expect(SidebarReorder.drawn(after).map(\.id.rawValue) == ["a", "c", "b"])
        #expect(pin(of: "c", in: after) == false)
    }

    @Test("A row dropped last in a project where everything is pinned stays pinned")
    func everythingPinned() {
        let rows = [
            workspace("a", order: 0, pinned: true),
            workspace("b", order: 1, pinned: true),
            workspace("c", order: 2, pinned: true),
        ]
        let visible = SidebarReorder.drawn(rows)
        let changes = SidebarReorder.move(visible: visible, all: rows, from: [0], to: 3)
        let after = applied(changes, to: rows)
        #expect(SidebarReorder.drawn(after).map(\.id.rawValue) == ["b", "c", "a"])
        #expect(after.filter(\.pinned).count == after.count)
    }

    @Test("The order a drop produces is the order the list draws next")
    func settledOrderIsStable() {
        let rows = [
            workspace("a", order: 0, pinned: true),
            workspace("b", order: 1),
            workspace("c", order: 2),
            workspace("d", order: 3),
        ]
        let visible = SidebarReorder.drawn(rows)
        for target in 0...visible.count {
            let changes = SidebarReorder.move(visible: visible, all: rows, from: [3], to: target)
            let after = applied(changes, to: rows)
            let expected = SidebarReorder.moving(visible.map(\.id.rawValue), from: [3], to: target)
            #expect(
                SidebarReorder.drawn(after).map(\.id.rawValue) == expected,
                "dropping at \(target) settled somewhere else"
            )
        }
    }

    // MARK: - Multiple rows

    @Test("A block of rows moves together and shares one pin state")
    func movingTwoRows() {
        let rows = [
            workspace("a", order: 0, pinned: true),
            workspace("b", order: 1),
            workspace("c", order: 2),
            workspace("d", order: 3),
        ]
        let visible = SidebarReorder.drawn(rows)
        let changes = SidebarReorder.move(visible: visible, all: rows, from: [2, 3], to: 0)
        let after = applied(changes, to: rows)
        #expect(SidebarReorder.drawn(after).map(\.id.rawValue) == ["c", "d", "a", "b"])
        #expect(after.first { $0.id == WorkspaceID("c") }?.pinned == true)
        #expect(pin(of: "d", in: after) == true)
    }

    // MARK: - The flattened pane

    /// Two projects with two rows each, as the pane draws them.
    ///
    ///     0  Alpha
    ///     1    a1
    ///     2    a2
    ///     3  Beta
    ///     4    b1
    ///     5    b2
    private var pane: [SidebarReorder.Row] {
        [
            .project(RepoID("alpha")),
            .workspace(id: WorkspaceID("a1"), projectID: RepoID("alpha")),
            .workspace(id: WorkspaceID("a2"), projectID: RepoID("alpha")),
            .project(RepoID("beta")),
            .workspace(id: WorkspaceID("b1"), projectID: RepoID("beta")),
            .workspace(id: WorkspaceID("b2"), projectID: RepoID("beta")),
        ]
    }

    @Test("A workspace dragged inside its project keeps the offsets it was dropped with")
    func flatWorkspaceInsideItsProject() {
        let destination = SidebarReorder.destination(rows: pane, from: [1], to: 3)
        #expect(destination == .workspace(
            projectID: RepoID("alpha"), from: IndexSet(integer: 0), to: 2, landedOutside: false
        ))
    }

    @Test("The offsets a workspace drag comes out with are its project's own, not the pane's")
    func flatWorkspaceOffsetsAreLocal() {
        let destination = SidebarReorder.destination(rows: pane, from: [5], to: 4)
        #expect(destination == .workspace(
            projectID: RepoID("beta"), from: IndexSet(integer: 1), to: 0, landedOutside: false
        ))
    }

    @Test("A workspace dropped in another project is brought back to the end it was dragged towards")
    func flatWorkspaceLandingOutside() {
        // Dropped between Beta's two rows, which is nowhere this workspace can go.
        let down = SidebarReorder.destination(rows: pane, from: [1], to: 5)
        #expect(down == .workspace(
            projectID: RepoID("alpha"), from: IndexSet(integer: 0), to: 2, landedOutside: true
        ))

        // And the same read from the other end: dragged up over the project above it.
        let up = SidebarReorder.destination(rows: pane, from: [5], to: 1)
        #expect(up == .workspace(
            projectID: RepoID("beta"), from: IndexSet(integer: 1), to: 0, landedOutside: true
        ))
    }

    @Test("A project dragged over another lands on the near side of it")
    func flatProjectMove() {
        // Dropped on Beta's own row, which is the boundary between the two projects.
        #expect(SidebarReorder.destination(rows: pane, from: [0], to: 3) == .project(id: RepoID("alpha"), to: 1))
        // Dropped past Beta's last row, which is the end of the list.
        #expect(SidebarReorder.destination(rows: pane, from: [0], to: 6) == .project(id: RepoID("alpha"), to: 2))
        // Dropped at the very top.
        #expect(SidebarReorder.destination(rows: pane, from: [3], to: 0) == .project(id: RepoID("beta"), to: 0))
    }

    @Test("A project dropped inside another lands on the boundary it was let go nearest")
    func flatProjectRoundsToTheNearestBoundary() {
        // Just under Beta's header is nearer the top of Beta than the bottom of it.
        #expect(SidebarReorder.destination(rows: pane, from: [0], to: 4) == .project(id: RepoID("alpha"), to: 1))
        // One row further down is nearer the end.
        #expect(SidebarReorder.destination(rows: pane, from: [0], to: 5) == .project(id: RepoID("alpha"), to: 2))
    }

    @Test("A collapsed project is one row that carries everything under it")
    func flatCollapsedProject() {
        let rows: [SidebarReorder.Row] = [
            .project(RepoID("alpha")),
            .project(RepoID("beta")),
            .workspace(id: WorkspaceID("b1"), projectID: RepoID("beta")),
        ]
        #expect(SidebarReorder.destination(rows: rows, from: [0], to: 3) == .project(id: RepoID("alpha"), to: 2))
    }

    @Test("The sentence an empty project draws is not something to move")
    func flatNoticeIsNotDragged() {
        let rows: [SidebarReorder.Row] = [
            .project(RepoID("alpha")),
            .notice(projectID: RepoID("alpha")),
            .project(RepoID("beta")),
            .workspace(id: WorkspaceID("b1"), projectID: RepoID("beta")),
        ]
        #expect(SidebarReorder.destination(rows: rows, from: [1], to: 3) == .nothing)
        // And it counts as a row for everything else: Beta's header is the second boundary.
        #expect(SidebarReorder.destination(rows: rows, from: [2], to: 0) == .project(id: RepoID("beta"), to: 0))
    }

    @Test("Offsets that are not in the pane are refused")
    func flatOffsetsOutOfRange() {
        #expect(SidebarReorder.destination(rows: pane, from: [9], to: 0) == .nothing)
        #expect(SidebarReorder.destination(rows: pane, from: [1], to: 99) == .nothing)
        #expect(SidebarReorder.destination(rows: [], from: [0], to: 0) == .nothing)
    }

    // MARK: - The projects' own order

    private func repo(_ id: String, order: Int) -> Repo {
        Repo(id: RepoID(id), name: id, path: "/tmp/\(id)", sortOrder: order)
    }

    @Test("Moving a project writes every project it passed and nothing else")
    func projectMoveWritesWhatChanged() {
        let repos = [repo("a", order: 0), repo("b", order: 1), repo("c", order: 2)]
        #expect(SidebarReorder.move(projects: repos, id: RepoID("a"), to: 3) == [
            SidebarReorder.ProjectChange(id: RepoID("b"), sortOrder: 0),
            SidebarReorder.ProjectChange(id: RepoID("c"), sortOrder: 1),
            SidebarReorder.ProjectChange(id: RepoID("a"), sortOrder: 2),
        ])
    }

    @Test("A project dropped where it already was writes nothing")
    func projectMoveThatChangesNothing() {
        let repos = [repo("a", order: 0), repo("b", order: 1), repo("c", order: 2)]
        #expect(SidebarReorder.move(projects: repos, id: RepoID("b"), to: 1).isEmpty)
        #expect(SidebarReorder.move(projects: repos, id: RepoID("b"), to: 2).isEmpty)
    }

    /// Every project added before the sidebar could be reordered carries the column's default, so
    /// the first drag in a project list is a drag over a list of zeroes. What comes out of it has
    /// to be an order, not a tie.
    @Test("A first drag over projects that all share one number still produces an order")
    func projectMoveFromEqualNumbers() {
        let repos = [repo("a", order: 0), repo("b", order: 0), repo("c", order: 0)]
        let changes = SidebarReorder.move(projects: repos, id: RepoID("a"), to: 3)
        let byID = Dictionary(changes.map { ($0.id, $0.sortOrder) }, uniquingKeysWith: { first, _ in first })
        let after = repos.map { ($0.id, byID[$0.id] ?? $0.sortOrder) }.sorted { $0.1 < $1.1 }
        #expect(after.map(\.0.rawValue) == ["b", "c", "a"])
        #expect(Set(after.map(\.1)).count == 3)
    }

    @Test("A project that is not in the list moves nothing")
    func projectMoveOfSomethingGone() {
        #expect(SidebarReorder.move(projects: [repo("a", order: 0)], id: RepoID("gone"), to: 0).isEmpty)
    }

    // MARK: - Rows that hang off the end of a project

    /// Alpha with a workspace being cut under its two stored rows.
    ///
    ///     0  Alpha
    ///     1    a1
    ///     2    a2
    ///     3    (being cut)
    ///     4  Beta
    ///     5    b1
    private var paneWithPending: [SidebarReorder.Row] {
        [
            .project(RepoID("alpha")),
            .workspace(id: WorkspaceID("a1"), projectID: RepoID("alpha")),
            .workspace(id: WorkspaceID("a2"), projectID: RepoID("alpha")),
            .pending(projectID: RepoID("alpha")),
            .project(RepoID("beta")),
            .workspace(id: WorkspaceID("b1"), projectID: RepoID("beta")),
        ]
    }

    /// The case the row was written for. A workspace being cut is drawn after its project's stored
    /// rows, so it sits between the last of them and the next project, and a drop below it is a
    /// drop at the end of that project rather than outside it. Clamping to the last workspace row
    /// instead reports `landedOutside` and shows the "Kept in" note for a drag that landed exactly
    /// where the insertion line said it would.
    @Test("A drop past a workspace being cut is still inside its project")
    func pendingRowDoesNotEndTheProject() {
        #expect(SidebarReorder.destination(rows: paneWithPending, from: [1], to: 4) == .workspace(
            projectID: RepoID("alpha"), from: IndexSet(integer: 0), to: 2, landedOutside: false
        ))
    }

    @Test("A workspace being cut cannot be picked up")
    func pendingRowDoesNotMove() {
        #expect(SidebarReorder.destination(rows: paneWithPending, from: [3], to: 1) == .nothing)
    }

    /// It counts as a row for a project header dragged past it, like every other row in the run.
    /// Beta's header is at 4 with the pending row above it, where it is at 3 without, and a
    /// boundary that did not count it would put a dragged project on the wrong side of Alpha.
    @Test("A workspace being cut takes an offset in the run")
    func pendingRowTakesAnOffset() {
        #expect(SidebarReorder.destination(rows: paneWithPending, from: [4], to: 0)
            == .project(id: RepoID("beta"), to: 0))
    }

    /// A project whose only row is one being cut. There is nothing to reorder, and nothing may be
    /// dropped into it, but it must not throw the offsets of the projects below it out.
    @Test("A project with nothing but a workspace being cut moves nothing")
    func projectOfOnlyPendingRows() {
        let rows: [SidebarReorder.Row] = [
            .project(RepoID("alpha")),
            .pending(projectID: RepoID("alpha")),
            .project(RepoID("beta")),
            .workspace(id: WorkspaceID("b1"), projectID: RepoID("beta")),
        ]
        #expect(SidebarReorder.destination(rows: rows, from: [1], to: 3) == .nothing)
        #expect(SidebarReorder.destination(rows: rows, from: [2], to: 0)
            == .project(id: RepoID("beta"), to: 0))
    }

    // MARK: - Helpers

    private func pin(of id: String, in rows: [Workspace]) -> Bool? {
        rows.first(where: { $0.id == WorkspaceID(id) })?.pinned
    }

    /// The rows as the store would hold them once every change has been written.
    private func applied(_ changes: [SidebarReorder.Change], to rows: [Workspace]) -> [Workspace] {
        let byID = Dictionary(changes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            guard let change = byID[row.id] else { return row }
            var updated = row
            updated.sortOrder = change.sortOrder
            updated.pinned = change.pinned
            return updated
        }
    }
}
