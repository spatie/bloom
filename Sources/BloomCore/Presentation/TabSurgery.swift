import Foundation

/// What a tab's arrangement becomes when a pane of it is closed, or when the thing one of its
/// panes was pointing at has gone.
///
/// Both of those are the same two decisions wearing different clothes, and both are decisions the
/// app used to take inside a store no test can reach: whether the tab survives at all, and what it
/// is called if the content it was named after has left. `Tests/BloomCoreTests` cannot see
/// `Sources/Bloom`, so a tab that quietly dissolved when it should have been re-filed is a bug
/// nothing could hold still. This is that pair of decisions, pure and total, with the store around
/// it left doing nothing but user defaults and observation.
///
/// **Closing a pane ejects, it never destroys.** Nothing here creates, kills or signals anything.
/// A pane leaves the tree and its pointer leaves the map, and because the strip is derived from
/// what no tab claims (see `TabSet.entries`), whatever that pane was holding is back in the strip
/// as an unsplit tab of its own on the next pass. Archiving a session and closing a tool tab are
/// the strip's own close buttons and they stay there.
public enum TabSurgery {
    public enum Outcome: Sendable, Equatable {
        /// Nothing in this arrangement matched, so nothing was written.
        case unchanged

        /// Still a tab. `root` is what it is filed under now, which is a different content from
        /// the one that went in when the old root left every pane of it, and the caller re-files
        /// the record: write the new key, then delete the old, never the other way round.
        case updated(root: PaneContent, stored: StoredPaneArrangement)

        /// One pane left, or none. The stored record goes, and `remaining` is what was in the last
        /// pane, which goes back to being an ordinary unsplit entry of the strip.
        case dissolved(remaining: PaneContent?)
    }

    /// One pane closed by hand: the Close Pane item, or the keystroke behind it.
    ///
    /// `.unchanged` covers both "this arrangement has no such pane" and "it is the only pane",
    /// which are the same answer to the caller: a column with one pane cannot be closed, and the
    /// strip's own close buttons are how a workspace loses a conversation or a tool.
    public static func closePane(
        _ pane: String, in stored: StoredPaneArrangement, root: PaneContent
    ) -> Outcome {
        guard var layout = SplitLayout(encoded: stored.layout), layout.contains(pane),
              layout.close(pane) else { return .unchanged }

        var contents = stored.contents
        contents[pane] = nil
        return settle(layout: layout, contents: contents, root: root)
    }

    /// The thing itself has gone: a session archived, a tool tab closed. Every pane of this tab
    /// pointing at it goes with it.
    ///
    /// Every pane rather than the first, because one chat can sit in two panes of one tab, which
    /// is the case `TabSet` allows on purpose. The doomed panes are read off the tree before the
    /// loop rather than inside it: closing one leaves the order of the others alone, so a snapshot
    /// walks each of them exactly once. That is `TabMigration.invert`'s reasoning and it holds here
    /// for the same reason.
    public static func remove(
        _ content: PaneContent, from stored: StoredPaneArrangement, root: PaneContent
    ) -> Outcome {
        guard var layout = SplitLayout(encoded: stored.layout) else { return .unchanged }
        var contents = stored.contents

        let doomed = layout.panes.filter { contents[$0] == content }
        guard !doomed.isEmpty else { return .unchanged }

        for pane in doomed {
            // False is the last pane, which cannot be closed. The tab dissolves below instead, so
            // a tab that was two views of one archived conversation goes rather than being left
            // standing on a pointer to nothing.
            guard layout.close(pane) else { break }
            contents[pane] = nil
        }
        return settle(layout: layout, contents: contents, root: root)
    }

    // MARK: - The two decisions

    /// Whether what is left is still a tab, and what it is called.
    ///
    /// Public because closing a pane is not the only way to reach these two questions: pointing a
    /// pane at something else can take the root out of the last pane holding it just as closing
    /// that pane would, and the answer has to be the same one either way.
    ///
    /// **One pane is not a tab.** An unsplit tab stores nothing, which is the free case
    /// `TabMigration.invert` also refuses to write down, and the survivor keeps the ordinary strip
    /// entry it would have had anyway.
    ///
    /// **A tab is named by a content in one of its panes.** When the root has left every pane, the
    /// first chat in pane order takes over, and failing that the first survivor. Same rule as
    /// `TabMigration.invert`, and for the same reason: a chat root files the tab in the strip's
    /// conversation run, which is where the eye is already looking for it.
    public static func settle(_ stored: StoredPaneArrangement, root: PaneContent) -> Outcome {
        guard let layout = SplitLayout(encoded: stored.layout) else { return .unchanged }
        return settle(layout: layout, contents: stored.contents, root: root)
    }

    private static func settle(
        layout: SplitLayout, contents: [String: PaneContent], root: PaneContent
    ) -> Outcome {
        let held = layout.panes.compactMap { contents[$0] }
        guard layout.paneCount > 1, let encoded = layout.encoded else {
            return .dissolved(remaining: held.first)
        }

        let survivors = StoredPaneArrangement(
            layout: encoded, contents: contents.filter { layout.contains($0.key) }
        )
        if held.contains(root) { return .updated(root: root, stored: survivors) }

        guard let refiled = held.first(where: \.isChat) ?? held.first else {
            // Every surviving pane points at nothing, so there is nothing to name a tab after.
            // Unreachable while the store writes an explicit pointer into every pane it opens,
            // which it does; this is the branch that says so rather than trapping.
            return .dissolved(remaining: nil)
        }
        return .updated(root: refiled, stored: survivors)
    }
}
