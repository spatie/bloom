import Foundation

/// One tab being carried along the strip, the way Safari carries one: the tab itself follows the
/// pointer and its neighbours slide into the slots they would have if it were let go now.
///
/// It replaces `TabDragOrder`, which answered a different question. That one rearranged the
/// `ForEach` behind a system drag, so the strip only learned where the pointer was from a drop
/// session and the thing under the pointer was AppKit's ghost image rather than the tab. What is
/// wanted is the tab, so the strip has to know every tab's DISPLAY offset for a given pointer, not
/// only the order, and that is arithmetic over widths and gaps that belongs where a test can reach
/// it rather than in a view.
///
/// Everything here is a snapshot taken when the drag began. Measuring the tabs again while they are
/// sliding would feed the answer back into itself and the strip would judder, which is the same
/// argument `TabDragOrder` made and the reason `spans` is a `let`.
///
/// **Tabs are not one width.** The strip shares its width out evenly when it can, but a crowded
/// strip holds every tab at its minimum while a rename field or a wider label can differ, so a
/// neighbour does not move by "one tab" but by exactly the dragged tab's width plus the gap it
/// leaves, and a tab jumping two slots moves past two different widths. `slotOffsets` lays the
/// row out again rather than assuming either.
public struct TabStripDrag: Equatable, Sendable {
    /// Where one tab sat along the strip when the drag began, in any one horizontal space.
    public struct Span: Equatable, Sendable {
        public var minX: Double
        public var width: Double

        public init(minX: Double, width: Double) {
            self.minX = minX
            self.width = width
        }

        public var maxX: Double { minX + width }
        public var midX: Double { minX + width / 2 }
    }

    /// The tabs in the order they are stored, as they were laid out before anything moved.
    public let spans: [Span]
    /// Which of them is being carried.
    public let dragged: Int

    /// Nil for a strip with nothing to rearrange: one tab, or an index that is not in it.
    public init?(spans: [Span], dragged: Int) {
        guard spans.count > 1, spans.indices.contains(dragged) else { return nil }
        self.spans = spans
        self.dragged = dragged
    }

    /// How far above or below the strip the pointer may wander and still be rearranging tabs rather
    /// than carrying one out to a pane. A hand dragging sideways drifts vertically, and a strip
    /// only 36 points tall that let go of the tab the moment the pointer left it would drop the tab
    /// back into its slot halfway through a reorder. Sixteen is less than half the strip, so a drag
    /// that is heading for the panes below still reaches them after a short, deliberate movement.
    public static let bandTolerance: Double = 16

    /// Whether a pointer at `y` is still rearranging the strip whose vertical extent is `band`.
    public static func isInStrip(_ y: Double, band: ClosedRange<Double>) -> Bool {
        y >= band.lowerBound - bandTolerance && y <= band.upperBound + bandTolerance
    }

    /// The pointer's horizontal travel, held to the strip: the carried tab stops with its leading
    /// edge on the first tab's and its trailing edge on the last tab's, as Safari's does, rather
    /// than sliding out over the strip's own ends.
    public func clamped(_ translation: Double) -> Double {
        let span = spans[dragged]
        let lower = spans[0].minX - span.minX
        let upper = spans[spans.count - 1].maxX - span.maxX
        return min(max(translation, lower), upper)
    }

    /// The slot the carried tab would take if it were let go after travelling `translation`.
    ///
    /// Decided by the carried tab's LEADING edge against the centres of the tabs before it, and its
    /// trailing edge against the centres of the tabs after it: a neighbour gives way once the
    /// carried tab covers half of it.
    ///
    /// Not the carried tab's own centre, which is what this was first written with and what the
    /// tests caught. With the travel clamped to the strip, a carried tab wider than the first tab
    /// has its centre stop short of the first tab's centre, so a wide tab could never be dragged
    /// into the first slot at all. An edge always reaches the far end's centre.
    ///
    /// Strictly past, so an edge resting exactly on a centre has not passed it: a drag held on a
    /// boundary does not flutter between two orders once a frame. Against the ORIGINAL centres
    /// rather than where the neighbours have slid to, because a neighbour that has already moved
    /// out of the way would otherwise be passed a second time on the way back.
    public func target(for translation: Double) -> Int {
        let travel = clamped(translation)
        let leading = spans[dragged].minX + travel
        let trailing = spans[dragged].maxX + travel
        let passedBefore = spans[..<dragged].filter { leading < $0.midX }.count
        let passedAfter = spans[(dragged + 1)...].filter { trailing > $0.midX }.count
        return dragged - passedBefore + passedAfter
    }

    /// How far each tab has to move from where it was laid out to where it would be with the
    /// carried tab in slot `target`, the carried tab included.
    ///
    /// The gaps between tabs (the separators) belong to the SLOTS rather than to the tabs, so the
    /// row is laid out again from the first tab's leading edge with the widths in their new order
    /// and the gaps where they were. Every offset is then a difference of two positions in one
    /// space, which is what lets a strip of unequal tabs rearrange without any of them overlapping.
    public func slotOffsets(target: Int) -> [Double] {
        let placed = order(Array(spans.indices), target: target)
        var offsets = [Double](repeating: 0, count: spans.count)
        var x = spans[0].minX

        for (slot, index) in placed.enumerated() {
            offsets[index] = x - spans[index].minX
            x += spans[index].width
            if slot < spans.count - 1 {
                x += spans[slot + 1].minX - spans[slot].maxX
            }
        }
        return offsets
    }

    /// What the strip draws after `translation` of travel: the slot the carried tab is heading
    /// for, and every tab's offset, where the carried tab's is the pointer's own clamped travel
    /// and every other tab's is its offset in that slot arrangement.
    public func offsets(for translation: Double) -> (target: Int, offsets: [Double]) {
        let target = target(for: translation)
        var offsets = slotOffsets(target: target)
        offsets[dragged] = clamped(translation)
        return (target, offsets)
    }

    /// `items`, stored in the same order as `spans`, rearranged with the carried one in `target`.
    ///
    /// Always a permutation of what it was given, so a drag can rearrange a strip and can do
    /// nothing else to it: it cannot lose a conversation or show one twice.
    public func order<Item>(_ items: [Item], target: Int) -> [Item] {
        guard items.indices.contains(dragged) else { return items }
        var rest = items
        let carried = rest.remove(at: dragged)
        rest.insert(carried, at: min(max(target, 0), rest.count))
        return rest
    }

    /// The strip with the tab at `index` moved one place along, for the accessibility actions that
    /// make reordering something other than a pointer gesture. Nil when there is no place to move
    /// to, so an action at the end of the strip can be left off rather than offered and ignored.
    public static func moved<Item>(_ items: [Item], from index: Int, by step: Int) -> [Item]? {
        let destination = index + step
        guard items.indices.contains(index), items.indices.contains(destination),
              destination != index else { return nil }
        var result = items
        result.swapAt(index, destination)
        return result
    }
}
