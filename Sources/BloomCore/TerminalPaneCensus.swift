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
/// under `center.tabs.<workspaceID>`, each expanded through the split tree it was last left in
/// under `terminal.split.<tab id>`. A tab nobody split is one pane carrying the tab's own id,
/// which is what keeps a shell forked before splitting existed exactly where it was.
///
/// It reads its own minimal record rather than `CenterTab`, which is a view layer type the core
/// cannot see, and that difference is deliberately in the safe direction. `CenterTabStore` decodes
/// the whole array and returns nothing at all if any element fails; this one needs two fields that
/// have been present since the first byte was written, so where they disagree this one names MORE
/// panes, and naming more panes only ever spares a shell.
public enum TerminalPaneCensus {
    /// `CenterTabStore`'s tool tab list, per workspace.
    public static let tabListPrefix = "center.tabs."
    /// `TerminalSplitStore`'s tree, per tab.
    public static let splitPrefix = "terminal.split."

    /// The two fields the sweep needs out of a stored tab. Everything else a tab carries, its
    /// title, its url, the file a review is reading, has nothing to say about a shell.
    private struct Tab: Decodable {
        var id: String
        var kind: String
    }

    private static let terminalKind = "terminal"

    public static func terminalTabs(of workspace: WorkspaceID, in defaults: UserDefaults) -> [String] {
        guard let data = defaults.data(forKey: tabListPrefix + workspace.rawValue),
              let tabs = try? JSONDecoder().decode([Tab].self, from: data) else { return [] }
        return tabs.filter { $0.kind == terminalKind }.map(\.id)
    }

    /// A tab nobody split has one pane, and it carries the tab's own id.
    public static func panes(ofTab tab: String, in defaults: UserDefaults) -> [String] {
        guard let encoded = defaults.string(forKey: splitPrefix + tab),
              let layout = SplitLayout(encoded: encoded) else { return [tab] }
        return layout.panes
    }

    /// The live set the sweep compares tmux's session list against.
    public static func livePanes(of workspaces: [WorkspaceID], in defaults: UserDefaults) -> Set<String> {
        var live: Set<String> = []
        for workspace in workspaces {
            for tab in terminalTabs(of: workspace, in: defaults) {
                live.formUnion(panes(ofTab: tab, in: defaults))
            }
        }
        return live
    }
}
