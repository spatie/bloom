import Foundation
import Testing
@testable import BloomCore

/// A drag in the strip, against the order the strip is derived from rather than the one it draws.
@Suite("TabReorder")
struct TabReorderTests {
    /// The regression this type was written for.
    ///
    /// Stored `[T1, T2, T3]` with `T2` absorbed into a pane of another tab draws as `[T1, T3]`.
    /// Taking the target's offset in the DRAWN list, 1, and applying it to the stored list gives
    /// `[T2, T1, T3]`, which reads back through the strip as `[T1, T3]`: the order the user
    /// started from. The tab sprang back under the pointer and the drag looked ignored.
    @Test("a tab dragged past a hidden one still moves in the strip")
    func hiddenEntryDoesNotSwallowTheMove() {
        let order = TabReorder.reorder(
            all: ["t1", "t2", "t3"], visible: ["t1", "t3"], moving: "t1", onto: "t3"
        )

        #expect(order == ["t2", "t3", "t1"])
        // What the strip makes of it, which is the half that used to come out unchanged.
        #expect(order?.filter { $0 != "t2" } == ["t3", "t1"])
    }

    @Test("the same drag the other way round lands the tab before the target")
    func hiddenEntryLeftwards() {
        let order = TabReorder.reorder(
            all: ["t1", "t2", "t3"], visible: ["t1", "t3"], moving: "t3", onto: "t1"
        )

        #expect(order == ["t3", "t1", "t2"])
        #expect(order?.filter { $0 != "t2" } == ["t3", "t1"])
    }

    @Test("a tab dropped on the one after it swaps the two")
    func rightwards() {
        #expect(
            TabReorder.reorder(all: ["a", "b", "c"], visible: ["a", "b", "c"], moving: "a", onto: "b")
                == ["b", "a", "c"]
        )
    }

    @Test("a tab dropped on the one before it swaps the two")
    func leftwards() {
        #expect(
            TabReorder.reorder(all: ["a", "b", "c"], visible: ["a", "b", "c"], moving: "b", onto: "a")
                == ["b", "a", "c"]
        )
    }

    @Test("a tab dragged across the run lands on the far side of the tab it was let go on")
    func acrossTheRun() {
        #expect(
            TabReorder.reorder(all: ["a", "b", "c"], visible: ["a", "b", "c"], moving: "a", onto: "c")
                == ["b", "c", "a"]
        )
        #expect(
            TabReorder.reorder(all: ["a", "b", "c"], visible: ["a", "b", "c"], moving: "c", onto: "a")
                == ["c", "a", "b"]
        )
    }

    /// A tab that comes back to the strip, its holder having been closed, must not make a tab
    /// somebody moved earlier appear to jump. Landing beside the target in the STORED run is what
    /// keeps that still.
    @Test("the moved tab comes to rest beside its target in the stored run")
    func besideTheTargetEvenWhereHiddenEntriesSit() {
        let order = TabReorder.reorder(
            all: ["a", "hidden", "b"], visible: ["a", "b"], moving: "a", onto: "b"
        )

        #expect(order == ["hidden", "b", "a"])
    }

    @Test("a tab dropped on itself writes nothing")
    func ontoItself() {
        #expect(TabReorder.reorder(all: ["a", "b"], visible: ["a", "b"], moving: "a", onto: "a") == nil)
    }

    /// The two lists cannot disagree about which way round the run is while `TabSet.entries`
    /// filters rather than reorders, but a write that changes nothing still costs a defaults key
    /// or a SQLite transaction, so it is refused rather than paid for.
    @Test("a drop that would change nothing writes nothing")
    func noChange() {
        #expect(TabReorder.reorder(all: ["a", "b"], visible: ["b", "a"], moving: "a", onto: "b") == nil)
    }

    @Test("something that is not in the strip is not a drag")
    func strangerToTheRun() {
        #expect(
            TabReorder.reorder(all: ["a", "b"], visible: ["a", "b"], moving: "z", onto: "a") == nil
        )
        #expect(
            TabReorder.reorder(all: ["a", "b"], visible: ["a", "b"], moving: "a", onto: "z") == nil
        )
    }

    /// A tab absorbed into a pane cannot be dragged, because it is not in the strip to be grabbed.
    /// Asked anyway, the answer is that nothing happens rather than that it is quietly moved.
    @Test("a tab that is not drawn cannot be dragged")
    func hiddenTabIsNotDraggable() {
        #expect(
            TabReorder.reorder(
                all: ["a", "hidden", "b"], visible: ["a", "b"], moving: "hidden", onto: "a"
            ) == nil
        )
    }

    @Test("a drop on a tab that is not drawn is not a drop")
    func hiddenTabIsNotATarget() {
        #expect(
            TabReorder.reorder(
                all: ["a", "hidden", "b"], visible: ["a", "b"], moving: "a", onto: "hidden"
            ) == nil
        )
    }

    /// The conversations run is keyed by `SessionID` and the tools run by `String`, so this has to
    /// answer for both without either being converted at the call site.
    @Test("the conversations run is decided by the same rule as the tools run")
    func typedIdentifiers() {
        let one = SessionID("s1")
        let two = SessionID("s2")
        let three = SessionID("s3")

        #expect(
            TabReorder.reorder(all: [one, two, three], visible: [one, three], moving: one, onto: three)
                == [two, three, one]
        )
    }
}
