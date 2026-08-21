import Foundation
import Testing
@testable import BloomCore

/// The strip as it is drawn, written back into the order it is stored in. The two are not the same
/// list, which is what made a drag on a strip with an absorbed tab in it do nothing at all.
@Suite("TabReorder")
struct TabReorderTests {
    /// The regression this type was written for.
    ///
    /// Stored `[t1, t2, t3]` with `t2` absorbed into a pane of another tab draws as `[t1, t3]`.
    /// Taking the target's offset in the DRAWN list and applying it to the stored one gave
    /// `[t2, t1, t3]`, which reads back through the strip as `[t1, t3]`: the order it started from.
    @Test("a run drawn without its absorbed tab still writes a change")
    func hiddenEntryDoesNotSwallowTheMove() {
        let order = TabReorder.apply(["t3", "t1"], to: ["t1", "t2", "t3"])

        #expect(order == ["t3", "t2", "t1"])
        #expect(order?.filter { $0 != "t2" } == ["t3", "t1"])
    }

    /// The hidden entries keep the exact slots they had, which is what stops a tab that later comes
    /// back to the strip from appearing to jump: it returns to the place it has held all along.
    @Test("what the strip cannot see does not move")
    func hiddenEntriesKeepTheirSlots() {
        let order = TabReorder.apply(["c", "a"], to: ["a", "hidden", "b", "c"])

        // The drawn entries are a, b and c, in slots 0, 2 and 3. Only a and c were drawn.
        #expect(order == ["c", "hidden", "b", "a"])
        #expect(order?[1] == "hidden")
    }

    @Test("a plain swap of two neighbours")
    func swap() {
        #expect(TabReorder.apply(["b", "a", "c"], to: ["a", "b", "c"]) == ["b", "a", "c"])
    }

    @Test("a tab carried the length of the run")
    func acrossTheRun() {
        #expect(TabReorder.apply(["b", "c", "a"], to: ["a", "b", "c"]) == ["b", "c", "a"])
        #expect(TabReorder.apply(["c", "a", "b"], to: ["a", "b", "c"]) == ["c", "a", "b"])
    }

    @Test("a tab let go where it started writes nothing")
    func noChange() {
        #expect(TabReorder.apply(["a", "b", "c"], to: ["a", "b", "c"]) == nil)
        #expect(TabReorder.apply(["a", "c"], to: ["a", "b", "c"]) == nil)
    }

    /// A stale reading must not be written: it would drop every stored entry it had forgotten or
    /// show one twice.
    @Test("a drawn order that does not account for what it claims to be writes nothing")
    func staleReading() {
        #expect(TabReorder.apply(["a", "z"], to: ["a", "b", "c"]) == nil)
        #expect(TabReorder.apply(["a", "a"], to: ["a", "b", "c"]) == nil)
        #expect(TabReorder.apply([String](), to: ["a", "b"]) == nil)
    }

    @Test("an empty run has nothing to write")
    func empty() {
        #expect(TabReorder.apply([String](), to: [String]()) == nil)
    }

    /// The conversations run is keyed by `SessionID` and the tools run by `String`, so this has to
    /// answer for both without either being converted at the call site.
    @Test("the conversations run is decided by the same rule as the tools run")
    func typedIdentifiers() {
        let one = SessionID("s1")
        let two = SessionID("s2")
        let three = SessionID("s3")

        #expect(TabReorder.apply([three, one], to: [one, two, three]) == [three, two, one])
    }

    /// Whatever is written is a permutation of what was stored. A reorder cannot lose a
    /// conversation or leave two of it.
    @Test("a written order holds exactly what the stored one held")
    func alwaysAPermutation() {
        let all = ["a", "hidden", "b", "c"]
        for visible in [["a", "b", "c"], ["c", "b", "a"], ["b", "c", "a"], ["c", "a"], ["b", "a"]] {
            guard let order = TabReorder.apply(visible, to: all) else { continue }
            #expect(order.count == all.count)
            #expect(Set(order) == Set(all))
        }
    }
}
