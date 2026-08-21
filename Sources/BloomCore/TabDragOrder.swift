import Foundation

/// What a run of tabs reads as while one of them is being dragged along the strip.
///
/// The tabs move out of the way under the pointer, so by the time the drag is let go the strip is
/// already showing the answer and the write behind it changes nothing on screen. That is worth more
/// than it sounds: a drop used to be the first moment anything moved, and whatever the system spent
/// tearing the drag down was a wait the user could see, with the gesture apparently ignored until
/// it ended.
///
/// The pointer's own position decides it, rather than how far it has travelled. A tab lands where
/// the pointer is, which is what direct manipulation means, and it needs nothing remembered from
/// the start of the gesture to work it out.
///
/// **The answer is always a permutation of the list it was given**, so whatever a run is taken to
/// be, a drag cannot add to it, lose from it, or leave it. It was once handed one of the strip's
/// two runs, which made a conversation dragged towards the shells stop dead at the last
/// conversation; it is handed the whole strip now, so nothing stops. The property is what matters
/// and it did not change: a drag rearranges a list and can do nothing else to it.
public enum TabDragOrder {
    /// The run as it should now read.
    ///
    /// - Parameters:
    ///   - run: the run in the order it is stored, which is the order it was drawn in before the
    ///     drag began.
    ///   - id: the tab being dragged.
    ///   - centres: where each tab of the run is centred along the strip, in any one space, as the
    ///     run was drawn BEFORE the drag. A snapshot on purpose: measuring them again while the
    ///     tabs are moving would feed the answer back into itself and the run would judder.
    ///   - pointer: where the pointer is now, in that same space.
    public static func live<ID: Hashable>(
        _ run: [ID], moving id: ID, centres: [ID: Double], to pointer: Double
    ) -> [ID] {
        guard run.contains(id), run.count > 1 else { return run }
        // Every tab measured, or nothing moves. A run drawn but not yet measured would otherwise
        // have its unmeasured tabs treated as being at one end, and the first frame of a drag would
        // throw the strip into an order nobody asked for.
        guard run.allSatisfy({ centres[$0] != nil }) else { return run }

        var others = run.filter { $0 != id }
        // Strictly less than, so a pointer resting exactly on a tab's centre has not passed it yet.
        // A tab therefore only moves once the pointer is properly past its middle, and a drag that
        // hovers on a boundary does not flutter between two orders.
        let index = others.filter { centres[$0]! < pointer }.count
        others.insert(id, at: min(index, others.count))
        return others
    }
}
