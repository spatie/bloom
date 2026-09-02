import Foundation

/// Whether the inspector slides in and out, or simply is or is not there.
///
/// **The crash this exists to stop.** Two reports, forty seconds apart, both `EXC_CRASH (SIGABRT)`
/// out of `AG::precondition_failure` with the same stack, on a window that had been running for
/// eighteen hours and then on one that had been running for thirty-two seconds. Read from the
/// bottom, what happens is:
///
///     GraphHost.flushTransactions -> AG::Subgraph::invalidate_now -> PlatformViewChild.destroy
///       -> OutlineListRepresentable.dismantleViewProvider -> destroyTableView
///       -> -[NSOutlineView removeFromSuperview] -> -[NSView _endLiveResize]
///       -> -[NSTableView viewDidEndLiveResize] -> -[NSTableRowData updateVisibleRowViews]
///       -> OutlineListCoordinator.outlineView(_:viewFor:item:) -> AGGraphGetValue -> abort
///
/// SwiftUI is tearing a `List` down, and AppKit, told to remove a table that is **in live resize**,
/// rebuilds that table's visible rows on the way out. The rebuild asks the list's coordinator for
/// a cell, the coordinator asks a view graph that is halfway through being invalidated, and
/// AttributeGraph aborts the process rather than answer.
///
/// Bloom has one `List` in the detail column, which is Home's, and two things that put that column
/// into live resize, both of them in `DetailSplitViewController.update` and both of them
/// animations: the split item's animated collapse, and `makeRoomForInspector`, which animates the
/// window's own frame when the inspector is arriving into a window too narrow to hold it. That
/// second one is why this is not constant. It only runs on a narrow window, which is what the
/// owner's was.
///
/// The same method assigns the panes' new content immediately above those animations, so selecting
/// a workspace from Home hands SwiftUI a tree with Home's list removed from it and then starts a
/// quarter-second live resize for it to be removed during.
///
/// **So the animation is dropped for exactly the case that crashes.** A transition where the
/// content is also changing is a full pane swap, where a sliding inspector is dressing on top of
/// something that has already replaced itself; a transition where it is not is the toolbar button
/// or Cmd+Option+I, which is the one where the slide is the whole point and where nothing is being
/// torn down for it to race. Reduce Motion already turned the same animation off for the same
/// underlying reason, and `DetailSplitViewController` says so: layout churn is the condition this
/// window has crashed under.
public enum InspectorTransition {
    /// - Parameters:
    ///   - motionAllowed: false when the system asks for reduced motion, which is already a
    ///     complete answer on its own.
    ///   - contentIsChanging: whether the detail column is showing something else in the same
    ///     update, which is the condition above.
    public static func isAnimated(motionAllowed: Bool, contentIsChanging: Bool) -> Bool {
        motionAllowed && !contentIsChanging
    }
}
