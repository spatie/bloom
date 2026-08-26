import Foundation

/// The chat that belongs to Bloom rather than to a workspace: what it is called, where it runs,
/// and what it is allowed to assume.
///
/// Everything the conversation itself needs already exists. `BridgeIdentity.owner` is a caller in
/// no workspace, `BridgeOwnerToken` is the credential that outlives a relaunch, and eleven owner
/// tools already list projects, list workspaces with their checks, register a repository and cut a
/// worktree. This type is the four decisions that were left: the directory, the mode, the name and
/// the words.
public enum AskConversation {
    /// What the chat is called, in the sidebar and on its row.
    public static let title = "Ask Bloom"

    /// The placeholder in the composer. It says what this chat is for, because a chat with no
    /// worktree looks exactly like a chat with one until you ask it something it cannot do.
    public static let placeholder = "Ask about your projects and workspaces, or ask for one"

    /// The mode it opens on, and it is not the app's default.
    ///
    /// `acceptEdits` grants this chat nothing it wants: there is no worktree here for an accepted
    /// edit to be in, and the one directory it does have is deliberately empty. So the default is
    /// the one that asks, and the composer still offers the other three for the day somebody wants
    /// one.
    public static let permissionMode = PermissionMode.auto

    /// The chat's working directory: its own, empty, and made once.
    ///
    /// **This is a permission decision rather than a tidiness one.** Bloom's default mode is
    /// `acceptEdits`, and a chat started in the owner's home directory under that mode would accept
    /// an edit anywhere in it without asking. An empty directory of its own makes every filesystem
    /// reach a reach *outside* the working directory, which is a reach that asks, and it pushes the
    /// agent towards the bridge tools instead, which are the audited surface.
    ///
    /// Beside the database rather than at a fixed path, for the reason `BridgeOwnerToken.beside`
    /// gives: `Store.databaseDirectoryName` is the one rule that decides which copy of Bloom a
    /// process is, so Bloom and Bloom Dev get their own without a second rule to keep in step.
    public static func directory(besideDatabaseAt databasePath: String) -> String {
        let container = (databasePath as NSString).deletingLastPathComponent
        return (container as NSString).appendingPathComponent("Ask")
    }

    /// The same, made on disk. Answers with the path, or nil when it could not be created, which
    /// is a chat that must not start: a `cwd` the CLI cannot enter is a process that dies at spawn,
    /// and falling back to any other directory would undo the whole paragraph above.
    public static func prepareDirectory(besideDatabaseAt databasePath: String) -> String? {
        let path = directory(besideDatabaseAt: databasePath)
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return path
        } catch {
            return nil
        }
    }

    /// A brand new Ask chat, with no workspace behind it.
    public static func newSession(sortOrder: Int = 0) -> Session {
        Session(
            workspaceID: nil,
            title: title,
            permissionMode: permissionMode,
            sortOrder: sortOrder
        )
    }

    /// What the empty pane says before anything has been asked.
    public static let emptyHeading = "One conversation, above every project"
    public static let emptyDetail =
        "This chat has no worktree. It can list what you have running, tell you which workspaces "
        + "have failing checks, register a repository, and start a workspace in one of them. "
        + "It cannot change a file."
}
