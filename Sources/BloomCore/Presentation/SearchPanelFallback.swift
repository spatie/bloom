import Foundation

/// The rows under a search that matched nothing.
///
/// **Two, and no more.** Raycast puts configurable fallback commands under an empty result and
/// hands them the text that matched nothing, so "ask this as a question" is a real ending for any
/// string. That is worth taking sparingly: somebody who searched for a workspace that does not
/// exist has just told you what to call it, which is the same argument the quick prompt panel
/// already makes for its "new quick prompt" row. A third row would be a menu.
///
/// Both are already in a menu, which is the rule the whole panel keeps: New Workspace is Cmd+N in
/// File and Search is Shift+Cmd+F in Edit. Nothing here is reachable only from the panel.
public enum SearchPanelFallback: Equatable, Sendable, Identifiable {
    /// Start a workspace named after what was typed.
    case startWorkspace(String)
    /// Hand the query to Home, which is where a long browse goes.
    case searchHome(String)

    public var id: String {
        switch self {
        case .startWorkspace: "start-workspace"
        case .searchHome: "search-home"
        }
    }

    public var query: String {
        switch self {
        case .startWorkspace(let query), .searchHome(let query): query
        }
    }

    public var title: String {
        switch self {
        case .startWorkspace(let query): "Start a workspace called \(query)"
        case .searchHome(let query): "Search Home for \(query)"
        }
    }

    /// The item in the menu bar this row is a shortcut to, so the row can print the same key that
    /// menu prints and cannot drift from it.
    public var action: MenuBarAction {
        switch self {
        case .startWorkspace: .newWorkspace
        case .searchHome: .search
        }
    }

    /// The two rows, in the order they are drawn.
    ///
    /// - Parameter hasProjects: whether a workspace can be started at all. With no project added
    ///   there is nothing to cut a worktree from, so the row would be a promise the app cannot
    ///   keep.
    public static func rows(for query: String, hasProjects: Bool) -> [SearchPanelFallback] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return (hasProjects ? [.startWorkspace(trimmed)] : []) + [.searchHome(trimmed)]
    }

    /// The sentence under the empty state, or nothing.
    ///
    /// **Only while the backfill is actually running.** The transcript index is built after launch,
    /// and until it finishes a "nothing matched" about work the user knows they did can be wrong.
    /// At any other time the same sentence would be an excuse rather than a fact, which is why it
    /// is keyed on the flag rather than printed always.
    public static func indexNotice(isIndexing: Bool) -> String? {
        isIndexing
            ? "The transcript index is still building, so older conversations are not searchable yet."
            : nil
    }

    /// The line above the two rows.
    public static func summary(for query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return "No workspace, transcript or command matches \(trimmed)."
    }
}
