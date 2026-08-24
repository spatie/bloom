import Foundation

/// Phase A: the panes a workspace was left in become the one tab that now owns them.
///
/// Until this ran, a workspace owned the split tree and the strip was a switcher for one pane, so
/// clicking a tab rewrote whatever the pane the user was standing in happened to hold. Containment
/// was inverted. This is the one way trip out of it: a workspace's whole carve becomes a single
/// composite tab, filed under the content at its root, and the strip goes back to listing tabs.
///
/// **It never touches a terminal key.** `center.tabs.*` and `terminal.split.*` are what the orphan
/// sweep reads to work out which shells anything in Bloom can still reach, and it kills every
/// session whose pane id it cannot enumerate. Commit 2e3d6e3 is the note that says why that
/// matters: a migration that changes what enumerates panes takes running shells with it, and there
/// is no way to get one back. Phase A moves one key to another key and leaves the sweep reading
/// exactly the data it read before. `TerminalPaneCensus` is that enumeration written down where a
/// test can hold it still either side of this.
///
/// The pane ids a carve holds never named a shell in any case: a terminal pane's id comes from
/// `terminal.split.<tab id>`, keyed by the `CenterTab`, and the carve's own ids are uuids that
/// never reached tmux. Both halves of the argument are worth keeping, because phase B folds the
/// shell trees in and only one of them survives it.
public enum TabMigration {
    /// One workspace's carve, as a tab.
    public struct CompositeTab: Sendable, Equatable {
        /// The content the tab is filed under and named by in the strip.
        public var root: PaneContent
        /// What to write under `TabDefaults.tabKey(root:)`.
        public var stored: StoredPaneArrangement

        public var key: String { TabDefaults.tabKey(root: root) }
    }

    // MARK: - The decision

    /// One workspace's carve folded into one tab, or nothing.
    ///
    /// Pure, total and deterministic, and it creates no identifier at all: the only edits it makes
    /// are closing panes. That is what makes it replayable, and replayable is what makes the trip
    /// safe, because the caller writes the new key before it deletes the old one and a crash
    /// between those two lines leaves this to run again on input it has not changed.
    ///
    /// Four rules, each one a thing the old model allowed that the new one cannot hold.
    ///
    /// - **A pane pointing at nothing is dropped.** It was showing the workspace's active
    ///   conversation, resolved on the fly, so it is a second view of whichever pane names that
    ///   chat rather than a pane of its own. `SplitLayout.close` collapses its split and hands the
    ///   space to the survivor, exactly as closing it by hand would.
    /// - **A chat may appear twice.** Two transcripts of one conversation sit side by side
    ///   happily, so nothing has to be thrown away to satisfy the one pane rule inside a tab.
    /// - **A tool may not.** A terminal and a browser are each one live `NSView`, and mounting one
    ///   in two places never worked. The first pane in order keeps it and the later one is closed,
    ///   because a migration must not carry a broken shape across.
    /// - **One pane left is not a tab.** An unsplit tab stores nothing, which is the same free
    ///   case `CenterPaneStore.persist` already relied on, and the surviving content keeps the
    ///   ordinary strip entry it would have had anyway.
    ///
    /// The tree shape, the ratios, the focus and above all **the pane ids** come through
    /// untouched. Focus needs no work: `SplitLayout.close` already moves it when it closes the
    /// pane holding it, and leaves it alone otherwise.
    public static func invert(_ old: StoredPaneArrangement) -> CompositeTab? {
        guard var layout = SplitLayout(encoded: old.layout) else { return nil }

        // `layout.panes` is read before the loop rather than in it. Closing a pane leaves the
        // order of the others alone, so a snapshot walks every original pane exactly once.
        for pane in layout.panes where old.contents[pane] == nil {
            _ = layout.close(pane)
        }

        var seenTools: Set<String> = []
        for pane in layout.panes {
            guard case .tool(let tool)? = old.contents[pane] else { continue }
            if seenTools.insert(tool).inserted { continue }
            _ = layout.close(pane)
        }

        guard layout.paneCount > 1, let encoded = layout.encoded else { return nil }

        let order = layout.panes
        let held = order.compactMap { old.contents[$0] }
        // A chat root files the composite in the strip's conversation run, which is where the eye
        // is already looking for it. A carve of nothing but tools has no chat to use.
        guard let root = held.first(where: \.isChat) ?? held.first else { return nil }

        // Every surviving pane gets an explicit entry, the root's included. Spelling the root out
        // is what retires the on the fly fallback: a pane with no entry used to mean "whatever the
        // workspace is talking to", and in the new model it means nothing at all.
        let contents = old.contents.filter { order.contains($0.key) }
        return CompositeTab(
            root: root, stored: StoredPaneArrangement(layout: encoded, contents: contents)
        )
    }

    // MARK: - The trip

    /// Runs phase A over a whole defaults domain, and returns what it made.
    ///
    /// Sorted, so two runs over the same domain do the same writes in the same sequence. Nothing
    /// depends on that today, but a migration whose behaviour turns on a dictionary's iteration
    /// order cannot be reproduced from a bug report.
    @discardableResult
    public static func migrateAll(in defaults: UserDefaults) -> [CompositeTab] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(TabDefaults.legacyCentrePrefix) }
            .sorted()
            .compactMap { migrate(legacyKey: $0, in: defaults) }
    }

    /// One workspace. Nil when it has no old key, or nothing in it worth a tab.
    @discardableResult
    public static func migrate(workspaceID: WorkspaceID, in defaults: UserDefaults) -> CompositeTab? {
        migrate(legacyKey: TabDefaults.legacyCentrePrefix + workspaceID.rawValue, in: defaults)
    }

    private static func migrate(legacyKey: String, in defaults: UserDefaults) -> CompositeTab? {
        guard let data = defaults.data(forKey: legacyKey) else { return nil }

        guard let old = StoredPaneArrangement(decoding: data),
              let tab = invert(old), let encoded = tab.stored.encoded else {
            // Nothing a rerun would fix, and leaving the key means reading it and failing on it on
            // every launch forever. An arrangement is the cheapest thing in this app to lose.
            defaults.removeObject(forKey: legacyKey)
            return nil
        }

        // The new key first and the old key second, never the other way round. Between these two
        // lines the arrangement exists twice, which the next run resolves; the other way round it
        // would exist nowhere, and a crash there loses it for good.
        defaults.set(encoded, forKey: tab.key)
        defaults.removeObject(forKey: legacyKey)
        return tab
    }
}
