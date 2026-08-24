import Foundation

/// A run of tabs as the strip now draws it, written back into the order it is actually stored in.
///
/// The strip is derived (`TabSet.entries`), so the list the user is dragging in is not the list the
/// store holds: anything absorbed as a pane of another tab has dropped out of the strip while
/// keeping its place in the stored run. Two lists, and an offset in one means nothing in the other.
/// That is the bug this exists for, and it was a silent one: stored `[T1, T2, T3]` with `T2`
/// absorbed draws as `[T1, T3]`, and dragging `T1` onto `T3` used to take the target's offset in
/// the DRAWN list, which is 1, and apply it to the stored one, giving `[T2, T1, T3]`. Read back
/// through the strip that is `[T1, T3]`, exactly what it was before, so the tab sprang back under
/// the pointer with nothing logged and nothing wrong on disk.
///
/// So the answer is stated in ids and the whole run comes back rewritten. `SidebarReorder` reaches
/// the same conclusion for the same reason, a drawn order and a stored order that are not the same
/// list, and this is the tab strip's much smaller version of it: there is no filter to respect and
/// no second ordering laid over the first, so the hidden entries need only keep the places they
/// already had.
///
/// It takes a whole drawn order rather than "this tab, dropped on that one", because by the time a
/// drag is let go the strip has already been showing the answer for as long as the user has been
/// dragging. `TabDragOrder` is what works that out; this is only how it is written down. Committing
/// a rule about the drop target instead would risk landing somewhere other than where the strip had
/// been saying it would land, which is the one thing a live preview must never do.
///
/// Generic over the id because it is asked three things that are keyed differently. A conversation
/// is a `SessionID` row in SQLite and a shell or a page is a `String` line in user defaults, and
/// each of those two lists has an order of its own to keep; the strip laid over both of them is a
/// list of `PaneContent`. Same rule, three callers, one implementation.
public enum TabReorder {
    /// The run's new stored order, or nil when there is nothing to write.
    ///
    /// The drawn entries take back the same SLOTS they already occupied in the stored run, in their
    /// new order, and everything hidden stays exactly where it was. That is what keeps a tab which
    /// later comes back to the strip, its holder having been closed, from appearing to jump: it
    /// returns to the place it has held all along.
    ///
    /// - Parameters:
    ///   - visible: the run as the strip now draws it.
    ///   - all: the run as it is stored, hidden entries and all.
    public static func apply<ID: Hashable>(_ visible: [ID], to all: [ID]) -> [ID]? {
        let drawn = Set(visible)
        // A drawn list that does not account for exactly the stored entries it claims to be a
        // reading of is a stale one, and writing it would drop or duplicate a tab.
        guard drawn.count == visible.count else { return nil }
        let slots = all.indices.filter { drawn.contains(all[$0]) }
        guard slots.count == visible.count else { return nil }

        var order = all
        for (slot, id) in zip(slots, visible) { order[slot] = id }

        // A drag that changes nothing is not a write. Reordering costs a defaults key or a SQLite
        // transaction, and a tab let go where it started must not pay either.
        return order == all ? nil : order
    }
}
