import Foundation

/// What choosing a run script from the tab strip's `+` menu does, given the tabs already open.
///
/// **A run script is a thing that is running or not, not a thing to open copies of.** Picking
/// `Vite` twice and getting two dev servers fighting over one port is never what was meant. So a
/// tab remembers which run script it was opened for, and picking the script again goes back to
/// that tab: to look at it when the command is still going, and to start it again in the same
/// place when it has stopped, which keeps its scrollback beside the new run.
///
/// Generic over the tab, so the app hands its own tab type straight in and says how to read the
/// two facts this needs. Whether a command is still running is a question for tmux, which the
/// core does not ask from here.
public enum RunScriptPick<Tab: Sendable & Hashable>: Sendable, Hashable {
    /// The script is still running in this tab. Show it.
    case focus(Tab)
    /// This tab ran the script and it has stopped. Run it again there.
    case rerun(Tab)
    /// No tab ran it. Open a new one.
    case open

    /// - Parameters:
    ///   - runScript: the id of the script that was picked.
    ///   - tabs: the workspace's tabs, in strip order.
    ///   - scriptOf: the run script id a tab was opened for, or nil for an ordinary tab.
    ///   - isRunning: whether that tab's command is still going.
    ///
    /// A running tab wins over an earlier stopped one, because going back to the live one is the
    /// only answer that cannot start a second copy. Among several of either kind, the first in the
    /// strip.
    public static func decide(
        runScript: String, tabs: [Tab], scriptOf: (Tab) -> String?, isRunning: (Tab) -> Bool
    ) -> RunScriptPick {
        let carrying = tabs.filter { scriptOf($0) == runScript }
        if let live = carrying.first(where: isRunning) { return .focus(live) }
        if let stopped = carrying.first { return .rerun(stopped) }
        return .open
    }
}
