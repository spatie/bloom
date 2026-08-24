import Foundation

/// Every terminal pane Bloom can still reach, read straight off user defaults.
///
/// This is the orphan sweep's own question, written where a test can ask it. `TmuxSessions.orphans`
/// kills every session whose pane id is not in this set, so the set is the difference between a
/// dev server that survives a quit and one that is killed by a launch nobody asked anything of.
/// Commit 2e3d6e3 is the note that says what that costs: a migration that changed what enumerates
/// panes would take running shells with it, and there is no way to get one back.
///
/// The path is exactly the sweep's. Per workspace still in the database, the terminal tabs listed
/// under `TabDefaults.tabListKey`, each expanded through the split tree it was last left in under
/// `TabDefaults.splitKey`. Both keys are built there and nowhere else, because this type and the
/// two view stores writing them used to declare the prefixes separately and nothing pinned them
/// together. A tab nobody split is one pane carrying the tab's own id, which is what keeps a
/// shell forked before splitting existed exactly where it was.
///
/// It reads its own minimal record rather than `CenterTab`, which is a view layer type the core
/// cannot see, and that difference is deliberately in the safe direction. `CenterTabStore` decodes
/// the whole array and returns nothing at all if any element fails; this one needs two fields that
/// have been present since the first byte was written, so where they disagree this one names MORE
/// panes, and naming more panes only ever spares a shell.
///
/// The two fields are still a wire contract with a type the core cannot see, so
/// `TerminalPaneCensusTests` pins them as bytes rather than as a type. Rename a coding key on
/// `CenterTab`, or change what `CenterTab.Kind.terminal` encodes as, and the answer here is not a
/// smaller set, it is the empty set, which is the killing answer rather than the sparing one.
/// Hence the doubt below.
public enum TerminalPaneCensus {
    /// What the sweep is allowed to act on.
    ///
    /// Two answers rather than one set, for the same reason `TerminalPersistence.sessions()`
    /// returns nil instead of an empty list: "asked, and there are no panes" is a fact, while
    /// "the record is there and could not be read" is not, and only the first may be acted on.
    /// Flattening both to a set is what makes a decode failure kill every shell in the workspace.
    public struct Census: Sendable, Equatable {
        /// Panes named by a record that read cleanly. The sweep keeps their sessions.
        public var panes: Set<String>
        /// Workspaces whose stored tabs or split trees are there but unreadable. The sweep must
        /// leave every session of these alone: it cannot name their panes, so it cannot tell a
        /// dead one from an `npm run dev` that has been up for a fortnight.
        public var doubtful: Set<WorkspaceID>

        public init(panes: Set<String> = [], doubtful: Set<WorkspaceID> = []) {
            self.panes = panes
            self.doubtful = doubtful
        }
    }

    /// The two fields the sweep needs out of a stored tab. Everything else a tab carries, its
    /// title, its url, the file a review is reading, has nothing to say about a shell.
    private struct Tab: Decodable {
        var id: String
        var kind: String
    }

    private static let terminalKind = "terminal"

    /// The terminal tabs of one workspace, or nil when a list is stored and could not be read.
    ///
    /// No key at all is a fact and answers with none: most workspaces have never had a centre
    /// terminal open, and treating that as doubt would mean the sweep never collected anything.
    /// Bytes that will not decode are the drift case, and that answers nil.
    public static func terminalTabs(of workspace: WorkspaceID, in defaults: UserDefaults) -> [String]? {
        guard let data = defaults.data(forKey: TabDefaults.tabListKey(workspace)) else { return [] }
        guard let tabs = try? JSONDecoder().decode([Tab].self, from: data) else { return nil }
        return tabs.filter { $0.kind == terminalKind }.map(\.id)
    }

    /// A tab nobody split has one pane, and it carries the tab's own id. Nil when a tree is stored
    /// and will not decode, because then the panes split off it have ids nothing here can name.
    public static func panes(ofTab tab: String, in defaults: UserDefaults) -> [String]? {
        guard let encoded = defaults.string(forKey: TabDefaults.splitKey(tab)) else { return [tab] }
        guard let layout = SplitLayout(encoded: encoded) else { return nil }
        return layout.panes
    }

    /// The live set the sweep compares tmux's session list against, and the workspaces it may not
    /// judge at all.
    public static func census(of workspaces: [WorkspaceID], in defaults: UserDefaults) -> Census {
        var census = Census()
        for workspace in workspaces {
            guard let tabs = terminalTabs(of: workspace, in: defaults) else {
                census.doubtful.insert(workspace)
                continue
            }
            for tab in tabs {
                guard let panes = panes(ofTab: tab, in: defaults) else {
                    census.doubtful.insert(workspace)
                    continue
                }
                census.panes.formUnion(panes)
            }
        }
        return census
    }
}
