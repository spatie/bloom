import Foundation

/// Which pointers a workspace's stored tabs are holding that nothing answers for any more.
///
/// A session can be archived, or a tool tab closed, in a launch that is not this one: the stores
/// that would have called `forget` were not running. Without this a restored pane sits on a dead
/// pointer showing an empty state, and the arrangement it is part of never heals. What is named
/// here is handed to `TabSurgery.remove`, so **everything this returns is destroyed**, and the
/// whole of the care below is about what may be named.
///
/// **An answer nobody has yet is not the answer "none".** Both lists are optional and nil means
/// "could not ask", which is the distinction `TerminalPaneCensus` was given for the orphan sweep
/// after a decode failure read as "no pane here is reachable" and took the shells with it. The
/// same trap was live here and cost an arrangement every launch: `WorkspaceTabsStore.reconcile`
/// ran from the tab strip's own `.task`, which has no suspension point in it, while
/// `WorkspaceModel.onAppear` was still on the `Store` actor waiting for the session query. So the
/// first visit to a workspace in each launch judged real tool tabs against an empty session list,
/// every chat pane of a tool rooted tab looked dead, and a terminal split with a conversation
/// beside it dissolved and had its `center.tab.*` key deleted before the sessions landed
/// milliseconds later. The layout was gone and written to disk; the conversation reappeared in the
/// strip as an unsplit tab, which is what made it look like the user had done it themselves.
///
/// A list that IS read and empty stays a fact and is acted on, because a workspace whose
/// conversations have all been archived is ordinary and its panes do have to heal.
public enum TabReconciliation {
    /// The contents to forget, in a stable order.
    ///
    /// `arrangements` is every split tab the store is holding, keyed by the content at its root,
    /// which is more than this workspace's. Only tabs whose root is one of the live things below
    /// are judged: an arrangement is filed under a content id and nothing else, so there is no key
    /// saying which workspace a tab belongs to, and asking whether its root is one of THIS
    /// workspace's things is the same question and the only one that can be answered. Walking all
    /// of them instead would judge another workspace's tabs against this workspace's sessions, and
    /// every one of them would look dead.
    ///
    /// A tab whose own root has gone is left alone, and is inert rather than wrong: `TabSet` only
    /// ever asks the tabs the strip has, so nothing such a tab holds is hidden by it.
    ///
    /// Sorted, so a workspace with two dead pointers heals the same way every launch: a tab whose
    /// root is one of them is re-filed, and which one is dealt with first decides what it is
    /// re-filed under.
    public static func dead(
        in arrangements: [PaneContent: StoredPaneArrangement],
        sessions: [SessionID]?,
        tools: [String]?
    ) -> [PaneContent] {
        let chats = sessions.map { Set($0.map(PaneContent.chat)) }
        let tools = tools.map { Set($0.map(PaneContent.tool)) }

        var dead: Set<PaneContent> = []
        for root in (chats ?? []).union(tools ?? []) {
            // A record whose layout will not decode is doubt of the same kind, and the panes it
            // holds cannot even be enumerated. Nothing is named from it.
            guard let stored = arrangements[root],
                  let layout = SplitLayout(encoded: stored.layout) else { continue }
            for pane in layout.panes {
                guard let content = stored.contents[pane] else { continue }
                let known = content.isChat ? chats : tools
                // Nil is the unasked list. A pointer of a kind we have no list for is left where
                // it is: it will be judged on a later pass, once there is something to judge it
                // against, and a pane left sitting on a stale pointer heals by itself while a
                // dissolved tab does not.
                guard let known, !known.contains(content) else { continue }
                dead.insert(content)
            }
        }
        return dead.sorted { $0.id < $1.id }
    }
}
