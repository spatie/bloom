import Foundation
import Testing
@testable import BloomCore

/// A tab carried along the strip the way Safari carries one: where it is drawn, where its
/// neighbours slide to, and which slot it lands in.
@Suite("TabStripDrag")
struct TabStripDragTests {
    /// Three tabs of unequal width with a one point separator between each, which is what the strip
    /// is: "Untitled" and "Fix the parser" are not the same size.
    ///
    ///     a: 0...100   b: 101...261   c: 262...382
    private let spans: [TabStripDrag.Span] = [
        .init(minX: 0, width: 100),
        .init(minX: 101, width: 160),
        .init(minX: 262, width: 120),
    ]

    private func drag(_ index: Int) throws -> TabStripDrag {
        try #require(TabStripDrag(spans: spans, dragged: index))
    }

    @Test("no movement changes nothing")
    func zeroMovement() throws {
        for index in spans.indices {
            let result = try drag(index).offsets(for: 0)
            #expect(result.target == index)
            #expect(result.offsets == [0, 0, 0])
        }
    }

    @Test("a tab whose edge has not passed its neighbour's centre keeps its slot")
    func shortOfTheCentre() throws {
        // a's trailing edge is 100 and b's centre is 181, so 81 of travel puts the edge exactly on
        // it, which has not passed it yet.
        let first = try drag(0)
        #expect(first.target(for: 80) == 0)
        #expect(first.target(for: 81) == 0)
        #expect(first.target(for: 81.001) == 1)
    }

    /// The case the first version of the rule got wrong: a tab wider than the first one, held to
    /// the strip, never had its centre reach the first tab's centre and so could never be dragged
    /// into the first slot.
    @Test("a tab wider than the first can still be dragged into the first slot")
    func wideTabToTheFront() throws {
        #expect(try drag(1).target(for: -10_000) == 0)
        #expect(try drag(2).target(for: -10_000) == 0)
    }

    /// The neighbour moves by the carried tab's width plus the gap, not by its own width, and the
    /// carried tab's slot is past the neighbour's width. With tabs of one width those are the same
    /// number and a wrong formula would pass.
    @Test("neighbours of a different width slide by the carried tab's width")
    func unequalWidths() throws {
        let result = try drag(0).offsets(for: 140)

        #expect(result.target == 1)
        // b now starts where a did.
        #expect(result.offsets[1] == -101)
        // c has not been passed.
        #expect(result.offsets[2] == 0)
        // The carried tab follows the pointer, not its slot.
        #expect(result.offsets[0] == 140)
        // Its slot is after b and one gap: 0 + 160 + 1.
        #expect(try drag(0).slotOffsets(target: 1)[0] == 161)
    }

    @Test("dragging the first tab to the end moves every other tab back one slot")
    func firstToLast() throws {
        let first = try drag(0)
        let result = first.offsets(for: 10_000)

        #expect(result.target == 2)
        #expect(result.offsets[1] == -101)
        #expect(result.offsets[2] == -101)
        // Held to the strip: its trailing edge stops on c's.
        #expect(result.offsets[0] == 282)
        #expect(first.slotOffsets(target: 2)[0] == 282)
        #expect(first.order(["a", "b", "c"], target: 2) == ["b", "c", "a"])
    }

    @Test("dragging the last tab to the start moves every other tab on one slot")
    func lastToFirst() throws {
        let last = try drag(2)
        let result = last.offsets(for: -10_000)

        #expect(result.target == 0)
        #expect(result.offsets[0] == 121)
        #expect(result.offsets[1] == 121)
        #expect(result.offsets[2] == -262)
        #expect(last.slotOffsets(target: 0)[2] == -262)
        #expect(last.order(["a", "b", "c"], target: 0) == ["c", "a", "b"])
    }

    @Test("dragging past either end is held at that end")
    func pastTheEnds() throws {
        let first = try drag(0)
        #expect(first.clamped(-50) == 0)
        #expect(first.target(for: -50) == 0)
        #expect(first.offsets(for: -50).offsets == [0, 0, 0])

        let last = try drag(2)
        #expect(last.clamped(50) == 0)
        #expect(last.target(for: 50) == 2)
        #expect(last.offsets(for: 50).offsets == [0, 0, 0])
    }

    @Test("a middle tab can go either way")
    func middle() throws {
        let middle = try drag(1)
        // b runs 101...261, a's centre is 50 and c's is 322.
        #expect(middle.target(for: -51) == 1)
        #expect(middle.target(for: -52) == 0)
        #expect(middle.target(for: 61) == 1)
        #expect(middle.target(for: 62) == 2)

        let left = middle.offsets(for: -52)
        #expect(left.offsets[0] == 161)
        #expect(left.offsets[2] == 0)

        let right = middle.offsets(for: 62)
        #expect(right.offsets[0] == 0)
        #expect(right.offsets[2] == -161)
    }

    /// Settled, the row has to be what it would be if it were laid out afresh in the new order: no
    /// overlap, no hole, and the separators where they were.
    @Test("every slot arrangement lays the row out without overlap")
    func slotsTile() throws {
        for index in spans.indices {
            let carried = try drag(index)
            for target in spans.indices {
                let offsets = carried.slotOffsets(target: target)
                let moved = spans.indices.map { spans[$0].minX + offsets[$0] }
                let order = carried.order(Array(spans.indices), target: target)
                var x = 0.0
                for (slot, tab) in order.enumerated() {
                    #expect(moved[tab] == x)
                    x += spans[tab].width + (slot < spans.count - 1 ? 1 : 0)
                }
            }
        }
    }

    @Test("the order is always a permutation")
    func permutation() throws {
        let items = ["a", "b", "c"]
        for index in spans.indices {
            let carried = try drag(index)
            for travel in stride(from: -600.0, through: 600.0, by: 13) {
                let order = carried.order(items, target: carried.target(for: travel))
                #expect(order.count == items.count)
                #expect(Set(order) == Set(items))
            }
        }
    }

    @Test("a strip of one tab, or a tab that is not in it, has nothing to carry")
    func nothingToCarry() {
        #expect(TabStripDrag(spans: [.init(minX: 0, width: 100)], dragged: 0) == nil)
        #expect(TabStripDrag(spans: spans, dragged: 3) == nil)
        #expect(TabStripDrag(spans: spans, dragged: -1) == nil)
    }

    @Test("the pointer is rearranging while it is inside the strip's band and a little beyond")
    func band() {
        let band = 0.0...36.0
        #expect(TabStripDrag.isInStrip(18, band: band))
        #expect(TabStripDrag.isInStrip(-TabStripDrag.bandTolerance, band: band))
        #expect(TabStripDrag.isInStrip(36 + TabStripDrag.bandTolerance, band: band))
        #expect(!TabStripDrag.isInStrip(36 + TabStripDrag.bandTolerance + 0.5, band: band))
        #expect(!TabStripDrag.isInStrip(-TabStripDrag.bandTolerance - 0.5, band: band))
    }

    @Test("moving a tab one place along swaps it with its neighbour, and not past the ends")
    func stepwise() {
        let items = ["a", "b", "c"]
        #expect(TabStripDrag.moved(items, from: 0, by: 1) == ["b", "a", "c"])
        #expect(TabStripDrag.moved(items, from: 2, by: -1) == ["a", "c", "b"])
        #expect(TabStripDrag.moved(items, from: 0, by: -1) == nil)
        #expect(TabStripDrag.moved(items, from: 2, by: 1) == nil)
        #expect(TabStripDrag.moved(items, from: 5, by: 1) == nil)
    }
}
