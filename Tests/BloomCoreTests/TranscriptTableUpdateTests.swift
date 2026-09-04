import Testing
import Foundation
@testable import BloomCore

/// **The three minute beach ball on the first launch after updating to 1.1.0.**
///
/// A `sample` of the wedged process put all 1,388 samples of the main thread in one stack:
/// `TranscriptTable.Coordinator.apply` into `-[NSTableView reloadData]`, then `purgeRowViewData`,
/// `removeAllKnownSubviews` and `_removeRowsBeingAnimatedOff`, tearing down one row view after
/// another inside `NSHostingView.viewWillMove(toWindow:)` and the KVO deregistration under it,
/// which is O(n) per view removed and so O(n²) for the lot.
///
/// AppKit only holds a row view in `_removeRowsBeingAnimatedOff` after
/// `removeRowsAtIndexes:withAnimation:`, and `apply` was the one place that staged a removal and
/// then reloaded the whole table in the same pass: the rows went out because the list had shrunk,
/// and the reload followed because the environment had moved. So the reload had every staged view
/// to tear off the window as well as the ones on screen.
///
/// Every case below is "what is the table told", and the rule the suite exists to hold is that
/// the answer is never two things at once.
@Suite("What a transcript table is told about a pass")
struct TranscriptTableUpdateTests {
    // MARK: - The hang

    /// The pass from the sample: the drawn list shrank, and the environment moved on the same
    /// pass. It used to stage the removal and then reload on top of it.
    @Test("a shrink with a moved environment is a reload and no removal")
    func shrinkWithAMovedEnvironmentStagesNothing() {
        let change = TranscriptEntryChange.shrank(head: 0..<40, tail: 0..<0)
        #expect(
            TranscriptTableUpdate.plan(change: change, environmentMoved: true) == .reload
        )
    }

    /// The same for rows arriving, which is the commoner shape and the same mistake.
    @Test("a growth with a moved environment is a reload and no insertion")
    func growthWithAMovedEnvironmentStagesNothing() {
        let change = TranscriptEntryChange.grew(head: 0..<400, tail: 0..<0)
        #expect(
            TranscriptTableUpdate.plan(change: change, environmentMoved: true) == .reload
        )
    }

    /// The invariant said once rather than case by case: whatever the rows did, a moved
    /// environment never asks for a row edit as well.
    @Test("a moved environment never stages rows, whatever the change was")
    func aMovedEnvironmentNeverStagesRows() {
        let changes: [TranscriptEntryChange] = [
            .same,
            .grew(head: 0..<3, tail: 0..<0),
            .grew(head: 0..<0, tail: 7..<9),
            .shrank(head: 0..<3, tail: 0..<0),
            .shrank(head: 0..<0, tail: 7..<9),
            .rebuilt,
        ]
        for change in changes {
            #expect(TranscriptTableUpdate.plan(change: change, environmentMoved: true) == .reload)
        }
    }

    // MARK: - And the cheap path is still the cheap path

    /// The whole point of `TranscriptEntryChange`: a row landing while the environment sits still
    /// is one insertion and not a reload. A regression here is the scroll stall coming back.
    @Test("a row arriving is an insertion")
    func aRowArrivingIsAnInsertion() {
        let change = TranscriptEntryChange.grew(head: 0..<0, tail: 12..<13)
        #expect(
            TranscriptTableUpdate.plan(change: change, environmentMoved: false)
                == .rows(.grew(head: 0..<0, tail: 12..<13))
        )
    }

    @Test("rows leaving are a removal")
    func rowsLeavingAreARemoval() {
        let change = TranscriptEntryChange.shrank(head: 4..<9, tail: 0..<0)
        #expect(
            TranscriptTableUpdate.plan(change: change, environmentMoved: false)
                == .rows(.shrank(head: 4..<9, tail: 0..<0))
        )
    }

    /// A list that did not move asks for no row edit at all. `.nothing` rather than
    /// `.rows(.same)`, so the caller has no empty branch to forget: the rows whose content moved
    /// are reloaded by index afterwards and are not this decision's business.
    @Test("the same list is no row edit at all")
    func theSameListIsNoEdit() {
        #expect(TranscriptTableUpdate.plan(change: .same, environmentMoved: false) == .nothing)
    }

    /// A session being replaced. Two lists that share no run cannot be expressed as rows in and
    /// out, so this one was always a reload and stays one.
    @Test("a rebuilt list is a reload")
    func aRebuiltListIsAReload() {
        #expect(TranscriptTableUpdate.plan(change: .rebuilt, environmentMoved: false) == .reload)
    }
}
