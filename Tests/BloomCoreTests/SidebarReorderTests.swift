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
            id: id,
            repoID: "r1",
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
        #expect(SidebarReorder.drawn(rows).map(\.id) == ["b", "d", "a", "c"])
    }

    // MARK: - The simple case

    @Test("Moving a row down writes every row it passed")
    func moveDown() {
        let rows = four
        let changes = SidebarReorder.move(visible: rows, all: rows, from: [0], to: 3)
        #expect(changes == [
            SidebarReorder.Change(id: "b", sortOrder: 0, pinned: false),
            SidebarReorder.Change(id: "c", sortOrder: 1, pinned: false),
            SidebarReorder.Change(id: "a", sortOrder: 2, pinned: false),
        ])
    }

    @Test("Moving a row up writes every row it passed")
    func moveUp() {
        let rows = four
        let changes = SidebarReorder.move(visible: rows, all: rows, from: [3], to: 1)
        #expect(changes == [
            SidebarReorder.Change(id: "d", sortOrder: 1, pinned: false),
            SidebarReorder.Change(id: "b", sortOrder: 2, pinned: false),
            SidebarReorder.Change(id: "c", sortOrder: 3, pinned: false),
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
        let order = SidebarReorder.drawn(applied(changes, to: rows)).map(\.id)
        // `a` lands after `c`, and `b` is still between where a was and c.
        #expect(order == ["b", "c", "a", "d"])
    }

    @Test("A drop at the top of a filtered pane lands above the first visible row, not the list")
    func filteredDropAtTop() {
        let rows = four
        // Only c and d are visible: a and b are hidden above them.
        let visible = [rows[2], rows[3]]
        let changes = SidebarReorder.move(visible: visible, all: rows, from: [1], to: 0)
        let order = SidebarReorder.drawn(applied(changes, to: rows)).map(\.id)
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
        #expect(visible.map(\.id) == ["a", "b", "c", "d"])
        // Drag `a` to the bottom.
        let changes = SidebarReorder.move(visible: visible, all: rows, from: [0], to: 4)
        let after = applied(changes, to: rows)
        #expect(SidebarReorder.drawn(after).map(\.id) == ["b", "c", "d", "a"])
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
        #expect(SidebarReorder.drawn(after).map(\.id) == ["d", "a", "b", "c"])
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
        #expect(SidebarReorder.drawn(after).map(\.id) == ["a", "c", "b"])
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
        #expect(SidebarReorder.drawn(after).map(\.id) == ["b", "c", "a"])
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
            let expected = SidebarReorder.moving(visible.map(\.id), from: [3], to: target)
            #expect(
                SidebarReorder.drawn(after).map(\.id) == expected,
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
        #expect(SidebarReorder.drawn(after).map(\.id) == ["c", "d", "a", "b"])
        #expect(after.first { $0.id == "c" }?.pinned == true)
        #expect(pin(of: "d", in: after) == true)
    }

    // MARK: - Helpers

    private func pin(of id: String, in rows: [Workspace]) -> Bool? {
        rows.first(where: { $0.id == id })?.pinned
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
