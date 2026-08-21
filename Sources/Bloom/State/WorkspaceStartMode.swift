import Foundation
import BloomCore

/// What a workspace opens on the first time you see it.
///
/// Deliberately a starting layout rather than a mode. A terminal workspace and a chat workspace
/// are the same thing: same worktree, same setup script, same inspector, same review and pull
/// request flow. The only difference is which tab has focus when the workspace opens, and either
/// kind can gain the other kind of tab afterwards from the `+` menu.
///
/// That is the whole reason this is one enum and a single stored flag rather than a mode: there is
/// no second set of rules to keep consistent, and nothing a workspace can be locked out of.
enum WorkspaceStartMode: String, CaseIterable, Identifiable {
    /// Describe a task, and the agent starts on it. The branch name is derived from what you typed.
    case chat
    /// A shell in the worktree, and you run whatever you like in it. You name the branch yourself,
    /// because there is no task to derive one from.
    case terminal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: "Chat"
        case .terminal: "Terminal"
        }
    }

    /// Written at creation and read when the workspace is first opened.
    ///
    /// User defaults rather than a column: this is a hint about the opening layout, it stops
    /// mattering the moment the user touches a tab, and putting it in the database would mean a
    /// migration for something that is allowed to be forgotten.
    static func defaultsKey(workspaceID: WorkspaceID) -> String {
        "workspace.opensOnTerminal.\(workspaceID)"
    }

    static func record(_ mode: WorkspaceStartMode, workspaceID: WorkspaceID) {
        guard mode == .terminal else { return }
        UserDefaults.standard.set(true, forKey: defaultsKey(workspaceID: workspaceID))
    }

    /// True once, for a workspace created as a terminal one that has not been opened yet. Reading
    /// it clears it, so re-selecting the workspace later does not keep forcing a terminal tab in
    /// front of whatever the user has since arranged.
    static func consumeOpensOnTerminal(workspaceID: WorkspaceID) -> Bool {
        let key = defaultsKey(workspaceID: workspaceID)
        guard UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.removeObject(forKey: key)
        return true
    }
}
