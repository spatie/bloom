import Foundation

/// What a transcript table is told about a pass: the rows that moved, or the whole thing again.
///
/// **This exists because telling it both in one pass beach balled the app for three minutes.**
/// A `sample` of 1.1.0 on the owner's machine put all 1,388 samples of the main thread in one
/// stack: `Coordinator.apply` into `-[NSTableView reloadData]`, then `purgeRowViewData`,
/// `removeAllKnownSubviews`, `_removeRowsBeingAnimatedOff`, and per row
/// `_removeViewAndAddToReuse:forRow:` into `removeFromSuperviewWithoutNeedingDisplay`. The leaves
/// were `NSHostingView.viewWillMove(toWindow:)` calling `removeObserver:forKeyPath:`, inside
/// `_NSKeyValueObservationInfoCreateByRemoving` and `NSKeyValueShareableObservationInfoNSHTHash`.
/// That is the window's observation info being rebuilt and rehashed once per hosting view removed,
/// which is O(n) each and therefore O(n²) for n rows coming off the window at once.
///
/// **`_removeRowsBeingAnimatedOff` is what names the pass.** AppKit only holds a row view there
/// after `removeRowsAtIndexes:withAnimation:`, and the one place a removal was followed by a full
/// reload was `apply`: `.shrank` staged rows out through `rowsLeft`, and then the environment
/// having moved reloaded the table on top of it, so the reload had every one of those staged
/// views to tear down as well as the ones on screen. Told one thing rather than two, the reload
/// is the only edit and the removal never happens. (Not proven from AppKit's own code: if
/// `removeAllKnownSubviews` routes ordinary row views through the same helper then the call site
/// this was read off flips, and nothing else here changes.)
///
/// **It is not a regression.** `TranscriptTable` is eleven lines different between 1.0.1 and
/// 1.1.0 and all eleven are a guard added elsewhere, so 1.0.1 does exactly the same thing. What
/// made it show up on the first launch after an update is the unread mark:
/// `TranscriptListView.mustReachIndex` opens the drawn window around the first unread row rather
/// than at the tail, which is the middle of the conversation, and the middle is where the runs of
/// rows that draw nothing are. Those are answered with a hundredth of a point until something has
/// measured them, so a viewport holds hundreds or thousands of them and the table builds a real
/// `NSHostingView` for every one. Read once, the mark is cleared and the next launch opens on the
/// last eighty rows, which is why quitting and reopening did not do it again.
///
/// What this does NOT fix is the number of realised rows, which is what makes n large in the
/// first place. See `TranscriptRowHeights.assumed` and `TranscriptTable`'s `viewFor` guard, which
/// only skips a row once it has been measured at nothing.
public enum TranscriptTableUpdate {
    /// The one edit a pass may make to the table's rows.
    public enum Plan: Equatable, Sendable {
        /// The list is the same list. Whatever changed is inside the rows, and the caller reloads
        /// those by index.
        case nothing
        /// Rows in or out, at the runs the change names. The cheap path, and the whole point of
        /// `TranscriptEntryChange`.
        case rows(TranscriptEntryChange)
        /// Every cell thrown away and the visible ones built again.
        case reload
    }

    /// **One edit per pass, and never a staged removal underneath a reload.**
    ///
    /// A moved environment is every cell whatever else happened, because a cell holds the values
    /// it was built in: see `TranscriptRowEnvironment`, and `cellGeneration`, which is what stops
    /// the reuse pool handing the same cells back. So it answers `.reload` and the rows are not
    /// staged at all. A rebuilt list is the same answer for its own reason, which is that the two
    /// lists share no run a table could be told about.
    ///
    /// `.same` is `.nothing` rather than `.rows(.same)`: there is no row edit to make, and saying
    /// so here means the caller has no empty branch to forget about.
    public static func plan(change: TranscriptEntryChange, environmentMoved: Bool) -> Plan {
        if environmentMoved || change == .rebuilt { return .reload }
        return change == .same ? .nothing : .rows(change)
    }
}
