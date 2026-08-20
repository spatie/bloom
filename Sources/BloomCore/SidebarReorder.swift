import Foundation

/// What a drag inside one project's rows changes about the workspaces stored under it.
///
/// The list is a `List` and the drag is `onMove`, which is `NSOutlineView`'s own row reordering,
/// so this is handed the two numbers that mechanism produces and nothing else: the offsets that
/// moved and the offset they were dropped at, both in the order the rows are DRAWN in. Turning
/// that into what the store should hold is the whole of this file, and it is here rather than in
/// a view because the drawn order and the stored order are not the same list.
///
/// They differ twice over.
///
/// A filter can be hiding rows. `SidebarFilter` lets the user narrow the pane to unread work or
/// to workspaces with changes, and a drop between two visible rows says nothing about the hidden
/// rows between them, which have to keep the places they already had. So a move is anchored to
/// the visible row it landed after, and the block is spliced in beside that row in the full
/// order. Dropping at the very top has no row before it, so it anchors to the visible row after
/// instead, which is the same rule read from the other end and is what keeps a drop at the top of
/// a filtered pane from jumping over rows the user cannot see.
///
/// Pinned rows sort first. That is a second ordering laid over `sort_order`, so writing the drawn
/// order straight back into `sort_order` is not enough: a pinned row dragged down among the
/// unpinned ones would be written where it was dropped and then drawn back at the top on the next
/// rebuild, which is a drop that undoes itself in front of the user. So a moved row ADOPTS the
/// pin state of where it lands: pinned if the row it now sits above is pinned, and if it lands
/// last, pinned if the row above it is. Dropping a row into the pinned block pins it, dragging it
/// out of the block unpins it, and either way the row stays exactly where it was let go. The pin
/// mark on the row is what says so, and it appears or disappears as part of the same settle.
///
/// The result is the smallest set of writes that produces the wanted order: a row whose
/// `sort_order` and `pinned` are both already right is not in it. Every one of them names the two
/// columns it changes, which is what `Store.update(workspaceID:)` is for.
public enum SidebarReorder {
    /// One row's new place. Never a whole `Workspace`: see `Store.update(workspaceID:)`.
    public struct Change: Equatable, Sendable {
        public var id: String
        public var sortOrder: Int
        public var pinned: Bool

        public init(id: String, sortOrder: Int, pinned: Bool) {
            self.id = id
            self.sortOrder = sortOrder
            self.pinned = pinned
        }
    }

    /// The order rows are drawn in: pinned first, then the user's own order.
    ///
    /// The one place this rule is written down. `AppModel.workspaces(in:)` and
    /// `SidebarRepoGroup.build` both sort by it, and a drag has to agree with them or it computes
    /// a destination for a list nobody is looking at.
    public static func drawn(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// `onMove`'s own semantics, written out because `move(fromOffsets:toOffset:)` is SwiftUI's
    /// and this target does not import it.
    ///
    /// The offsets index the list BEFORE anything is taken out of it, and `to` is the place the
    /// block lands in that same numbering, which is why dropping a row on the place it already
    /// occupies can arrive here as either its own offset or the one after it. Both are a move of
    /// nothing, and both come out of here as the list unchanged.
    public static func moving<Element>(
        _ elements: [Element], from: IndexSet, to: Int
    ) -> [Element] {
        let block = from.sorted().map { elements[$0] }
        let taken = from.filter { $0 < to }.count
        var result = elements
        for offset in from.sorted(by: >) { result.remove(at: offset) }
        result.insert(contentsOf: block, at: max(0, min(to - taken, result.count)))
        return result
    }

    /// - Parameters:
    ///   - visible: the project's rows as they are drawn, which is what the filter is letting
    ///     through, in the order `onMove`'s offsets index into.
    ///   - all: every workspace in the project, filtered by nothing.
    ///   - from: the offsets that moved, in `visible`.
    ///   - to: the offset they were dropped at, in `visible`, before the moved rows are taken
    ///     out. These are `onMove`'s own semantics, which are `Array.move(fromOffsets:toOffset:)`.
    public static func move(
        visible: [Workspace], all: [Workspace], from: IndexSet, to: Int
    ) -> [Change] {
        let drawnVisible = visible.map(\.id)
        guard from.allSatisfy({ drawnVisible.indices.contains($0) }) else { return [] }

        let afterMove = moving(drawnVisible, from: from, to: to)
        let moved = from.map { drawnVisible[$0] }
        let movedIDs = Set(moved)
        guard !movedIDs.isEmpty else { return [] }

        // `move(fromOffsets:toOffset:)` leaves the moved rows in one run, so the block is found by
        // its first row and is as long as the number of rows that moved.
        guard let head = afterMove.firstIndex(where: { movedIDs.contains($0) }) else { return [] }
        let tail = head + moved.count - 1
        let anchorBefore = head > 0 ? afterMove[head - 1] : nil
        let anchorAfter = tail + 1 < afterMove.count ? afterMove[tail + 1] : nil

        var order = drawn(all).map(\.id)
        // A row the filter is hiding is not in `visible` and must not be treated as having moved.
        let block = order.filter { movedIDs.contains($0) }
        order.removeAll { movedIDs.contains($0) }

        let insertion: Int
        if let anchorBefore, let index = order.firstIndex(of: anchorBefore) {
            insertion = index + 1
        } else if let anchorAfter, let index = order.firstIndex(of: anchorAfter) {
            insertion = index
        } else {
            // Nothing visible to anchor to, which is a project whose only visible rows are the
            // ones being dragged. There is no order to change.
            return []
        }
        order.insert(contentsOf: block, at: insertion)

        let stored = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pinnedNow = pinned(after: order, moved: movedIDs, stored: stored)

        return order.enumerated().compactMap { index, id in
            guard let workspace = stored[id] else { return nil }
            let wantsPinned = pinnedNow[id] ?? workspace.pinned
            guard workspace.sortOrder != index || workspace.pinned != wantsPinned else { return nil }
            return Change(id: id, sortOrder: index, pinned: wantsPinned)
        }
    }

    /// What each moved row's pin state becomes.
    ///
    /// Read off the row below the block, because the pinned rows are the ones at the top: a block
    /// that still has a pinned row under it is inside the pinned run, and one that does not is
    /// below it. A block dropped at the very end has nothing under it and reads the row above
    /// instead, which is the only case where the answer comes from the other side and is what
    /// makes a project whose rows are all pinned behave.
    ///
    /// Every row in the block gets the same answer, so a multiple selection cannot be split
    /// across the boundary and leave the two orders disagreeing.
    private static func pinned(
        after order: [String], moved: Set<String>, stored: [String: Workspace]
    ) -> [String: Bool] {
        guard let head = order.firstIndex(where: { moved.contains($0) }) else { return [:] }
        let tail = order.lastIndex(where: { moved.contains($0) }) ?? head

        let neighbour = tail + 1 < order.count ? order[tail + 1] : (head > 0 ? order[head - 1] : nil)
        guard let neighbour, let workspace = stored[neighbour] else { return [:] }

        var answer: [String: Bool] = [:]
        for id in order where moved.contains(id) { answer[id] = workspace.pinned }
        return answer
    }
}
