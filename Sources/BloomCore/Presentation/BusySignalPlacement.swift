import Foundation

/// Where a column of tabs says it is busy: nowhere, along the column's top edge, or in particular
/// tabs.
///
/// # Where it has been, and why it is here
///
/// The signal used to be a crest lighting the rule that closes off the tab strip, full width,
/// whenever the workspace had a turn running. Two things broke that. The strip stopped being drawn
/// for a lone tab (`TabStripVisibility`), and the rule went with it, so the most common window, one
/// conversation, showed no busy signal at all. And with several tabs, one line across all of them
/// could say that something was working but never which.
///
/// So it moved to two places: along the column's top edge with no strip, and a short crest under
/// each busy tab with one. The owner's report on that was that the tab's crest sat underneath the
/// tab rather than being part of it, and the column's read as a hard blue line under the title bar.
/// A shimmer through the busy tab's name, or through the window title with no strip, came next,
/// and was reported as too subtle in both places, with too little text in a short name to animate.
///
/// What is drawn now is Safari's loading sweep (`BusySweep`). Still two places and never both.
/// **No strip**: a short segment slides along the column's top edge, with no track behind it.
/// **A strip**: a band sweeps through each busy tab's capsule, and the column's edge stays dark.
/// The single answer is what stops the two overlapping while the strip appears or goes: the column
/// asks this once and hands the same value to the strip and to its own top edge.
///
/// # What counts as busy
///
/// A tab is busy when anything in any of its panes is running, not only the content it is filed
/// under. A split tab is one entry in the strip standing for every pane in it, and a turn running
/// in its second pane is running in that tab; marking only the root would leave a working split
/// looking idle. With no strip that is the visible tab, which is the only tab there is.
///
/// What "running" means for one content is the caller's, and it is exactly what the tab's dot used
/// to be driven by: a chat's agent mid turn (including a CLI agent linked to it in a terminal, and
/// its subagents), and a run script's command. A plain terminal never counts; nothing polls it.
public enum BusySignalPlacement<Tab: Hashable & Sendable>: Equatable, Sendable {
    /// Nothing is running, or nothing is showing.
    case none
    /// The column's top edge, because there is no strip.
    case columnTop
    /// Each of these tabs' capsules. Never empty; an empty set is `none`.
    case tabs(Set<Tab>)

    /// - Parameters:
    ///   - isStripShown: whether the column draws its strip, which is `TabStripVisibility`'s.
    ///   - tabs: the strip's entries, in any order.
    ///   - selected: the tab the column is showing.
    ///   - panes: what each pane of a tab shows. A tab nobody split is one pane showing itself.
    ///   - isRunning: whether one content is running.
    public static func resolve(
        isStripShown: Bool,
        tabs: [Tab],
        selected: Tab?,
        panes: (Tab) -> [Tab] = { [$0] },
        isRunning: (Tab) -> Bool
    ) -> Self {
        func isBusy(_ tab: Tab) -> Bool {
            panes(tab).contains(where: isRunning)
        }

        guard isStripShown else {
            // The visible tab, falling back to the only one when the selection has not resolved
            // yet. More than one tab with no strip is a state `TabStripVisibility` never answers,
            // and guessing which of them is on screen would light the edge for the wrong one.
            let visible = selected.flatMap { tabs.contains($0) ? $0 : nil }
                ?? (tabs.count == 1 ? tabs.first : nil)
            guard let visible, isBusy(visible) else { return .none }
            return .columnTop
        }

        let busy = Set(tabs.filter(isBusy))
        return busy.isEmpty ? .none : .tabs(busy)
    }

    /// Whether the column's top edge carries the signal.
    public var showsColumnTop: Bool {
        self == .columnTop
    }

    /// Whether this tab's capsule carries the signal.
    public func showsInTab(_ tab: Tab) -> Bool {
        guard case .tabs(let busy) = self else { return false }
        return busy.contains(tab)
    }
}
