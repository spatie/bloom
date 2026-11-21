import Foundation

/// Whether Home's view tree exists, and whether it is the pane the window is showing.
///
/// **Home is kept once it has been visited, because tearing its list down can abort the app.**
/// Home is a SwiftUI `List`, which is an `NSOutlineView` underneath. When the selection leaves
/// Home while the window is in live resize, which is a window edge or either divider being
/// dragged or an animated frame change, SwiftUI dismantles that table inside its own update.
/// AppKit, told to remove a table that is in live resize, ends the live resize on the way out, and
/// `-[NSTableView viewDidEndLiveResize]` rebuilds the visible rows. The rebuild asks the list's
/// coordinator for cells, the coordinator reads a view graph that is halfway through being
/// invalidated, and AttributeGraph stops the process:
///
///     GraphHost.flushTransactions -> AG::Subgraph::invalidate_now -> PlatformViewChild.destroy
///       -> OutlineListRepresentable.dismantleViewProvider -> destroyTableView
///       -> -[NSOutlineView removeFromSuperview] -> -[NSView _endLiveResize]
///       -> -[NSTableView viewDidEndLiveResize] -> -[NSTableRowData updateVisibleRowViews]
///       -> OutlineListCoordinator.outlineView(_:viewFor:item:) -> DynamicViewPhase.value
///       -> AG::Graph::resolve_offset -> AG::precondition_failure -> abort
///
/// Two of the owner's crash reports, on 1.39.6, are that stack. `TeardownProbe` replays it against
/// a copy of the owner's database: with the window in live resize, three runs out of three
/// aborted in the first or second cycle; without it, three out of three ran thirty cycles clean.
///
/// `InspectorTransition` was the first answer to it, and it keeps the inspector from STARTING a
/// live resize in the same update that swaps the pane. It cannot cover a live resize that is
/// already running, such as a drag the reader is making, when something else moves the selection
/// away from Home. Which of those it was on the owner's Mac is not known; the reports only say
/// that the table was in live resize when it was removed. So the list is never torn down instead.
/// The workspace columns are kept behind the selected pane for a cheaper return (see
/// `DetailColumn`), and Home is kept beside them for this.
///
/// Not before the first visit: a window that opens on a workspace and never goes to Home does
/// not pay for a list of every workspace on the machine. After it, Home is not free: folded out of
/// sight it still made a window resize step 3 to 9 per cent dearer on the main thread, measured
/// with `ResizeProbe --resize-visit-home`. That is the price of a list that cannot abort the app.
public struct HomePresence: Sendable, Equatable {
    /// Whether the selection has been Home at least once in this window.
    public private(set) var hasVisited: Bool

    public init(hasVisited: Bool = false) {
        self.hasVisited = hasVisited
    }

    /// Records where the selection went.
    public mutating func select(_ selection: SidebarSelection) {
        if Self.isPresented(selection) { hasVisited = true }
    }

    /// Whether Home's view tree should exist for this selection.
    public func isMounted(for selection: SidebarSelection) -> Bool {
        hasVisited || Self.isPresented(selection)
    }

    /// Whether Home is the pane the window is showing.
    public static func isPresented(_ selection: SidebarSelection) -> Bool {
        selection == .home
    }
}
