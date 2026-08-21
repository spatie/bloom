import Foundation

/// Where a tab dragged onto another tab ends up in the order that is actually stored.
///
/// The strip is derived (`TabSet.entries`), so the list the user is dragging in is not the list
/// the store holds: anything absorbed as a pane of another tab has dropped out of the strip while
/// keeping its place in the stored run. Two lists, and an offset in one means nothing in the
/// other. That is the bug this exists for, and it was a silent one.
///
/// Stored `[T1, T2, T3]` with `T2` absorbed draws as `[T1, T3]`. Dragging `T1` onto `T3` used to
/// take the target's offset in the DRAWN list, which is 1, and apply it to the stored list:
/// `[T2, T1, T3]`. Read back through the strip that is `[T1, T3]`, exactly what it was before, so
/// the tab sprang back under the pointer and the drag looked like it had not been noticed. Nothing
/// logged, nothing wrong on disk, just a gesture that did nothing.
///
/// So the answer is stated in ids rather than in offsets, and the whole run comes back rewritten.
/// `SidebarReorder` reaches the same conclusion for the same reason, a drawn order and a stored
/// order that are not the same list, and this is the tab strip's much smaller version of it: one
/// tab moves, there is no filter to respect and no second ordering laid over the first, so the
/// hidden entries need only keep the places they already had.
///
/// Generic over the id because the strip's two runs are keyed differently: a conversation is a
/// `SessionID` row in SQLite, a shell or a page is a `String` line in user defaults. Neither run
/// can be dragged into the other (see `TabSet`), so one run at a time is the whole of the job.
public enum TabReorder {
    /// The run's new stored order, or nil when there is nothing to write.
    ///
    /// The moved tab lands on the FAR side of the tab it was let go on, in the direction it
    /// travelled: dragged rightwards it comes to rest after the target, dragged leftwards before
    /// it. That is what every tab strip on this platform does, and it is the only reading that
    /// makes dropping a tab on its neighbour swap the two rather than leave them where they were.
    /// A drop's offset is all the mechanism gives us, so there is no midpoint to read and no third
    /// answer to give.
    ///
    /// It lands immediately beside the target in the STORED run, not merely somewhere that reads
    /// correctly in the drawn one. A tab absorbed into a pane of another tab can come back to the
    /// strip later (its holder closes, `TabSurgery` hands the pane's content back), and a moved
    /// tab parked on the far side of it would appear to jump when that happened. Beside the target
    /// is the one place that survives the hidden entries becoming visible again.
    ///
    /// - Parameters:
    ///   - all: the run as it is stored, hidden entries and all.
    ///   - visible: the run as the strip draws it, which is `all` minus whatever a tab has
    ///     absorbed. It decides the direction of travel and nothing else.
    ///   - id: the tab being dragged.
    ///   - target: the tab it was let go on.
    public static func reorder<ID: Hashable>(
        all: [ID], visible: [ID], moving id: ID, onto target: ID
    ) -> [ID]? {
        guard id != target,
              let from = visible.firstIndex(of: id),
              let to = visible.firstIndex(of: target),
              all.contains(id)
        else { return nil }

        var order = all
        order.removeAll { $0 == id }
        // After the removal the target is still in there, because a tab cannot be dropped on
        // itself and the guard above has already said so.
        guard let anchor = order.firstIndex(of: target) else { return nil }
        order.insert(id, at: from < to ? anchor + 1 : anchor)

        // Belt and braces, for a caller whose two lists disagree about which way round the run
        // is. They cannot as things stand, because `TabSet.entries` filters the stored run and
        // never reorders it, so the direction read off the drawn list is the direction in the
        // stored one. A write costs a defaults key or a SQLite transaction all the same, and one
        // that changes nothing should not be paid for.
        return order == all ? nil : order
    }
}
