import Foundation

/// Which gaps of a tab strip carry a divider, measured off Safari's tab bar on macOS 26.
///
/// Safari draws a short rule between two tabs only when both of them are at rest. The selected
/// tab's capsule is its own edge, a hovered tab's highlight fills the slot the rule sat in, and a
/// tab lifted by the pointer is a plate of its own. A rule beside any of those reads as a line
/// poking out of the capsule, so a gap shows one only when neither neighbour is any of the three.
///
/// A busy tab is a fourth. It carries a faint capsule of house blue with a band sweeping through
/// it (`BusySweep`), so it has an edge of its own the way the selected tab does, and a rule
/// against that edge reads the same way: as a line poking out of a capsule.
///
/// Every input is a SLOT, a position along the strip as it is drawn, rather than a position in
/// the stored order. During a drag the two differ: the neighbours have slid to make room, and the
/// rule that has to go is the one beside where the lifted tab is heading, not beside where it was.
public enum TabStripDividers {
    /// One answer per gap, where element `i` is the gap between slot `i` and slot `i + 1`. Empty
    /// for a strip of fewer than two tabs, which has no gap.
    ///
    /// A slot outside the strip names no tab and hides nothing, so a hover that arrives a frame
    /// after the tab under it closed cannot take a neighbour's rule with it.
    public static func visible(
        count: Int, selected: Int?, hovered: Int?, dragged: Int?, busy: Set<Int> = []
    ) -> [Bool] {
        guard count > 1 else { return [] }
        let occupied = Set([selected, hovered, dragged].compactMap { $0 }).union(busy)
        return (0..<(count - 1)).map { !occupied.contains($0) && !occupied.contains($0 + 1) }
    }

    /// The same rule over the tabs themselves, in the order the strip is drawing them. A tab that
    /// is not in `order` occupies no slot.
    public static func visible<Item: Equatable>(
        in order: [Item], selected: Item?, hovered: Item?, dragged: Item?, busy: [Item] = []
    ) -> [Bool] {
        func slot(_ item: Item?) -> Int? { item.flatMap { order.firstIndex(of: $0) } }
        return visible(
            count: order.count, selected: slot(selected), hovered: slot(hovered), dragged: slot(dragged),
            busy: Set(busy.compactMap(slot))
        )
    }
}
