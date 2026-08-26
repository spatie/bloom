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

    /// The mode it opens on, and it is deliberately not the app's default.
    ///
    /// **The default is Full access.** `AppDefaults.fallbackPermissionMode` is
    /// `bypassPermissions`, and the Models tab can pin anything over it, so this chat inheriting
    /// the owner's default would have meant an agent above every project running whatever it liked
    /// without asking. That default is a reasonable one for a worktree, which is a copy: the
    /// argument for it is that a session which stops before its first command is a session somebody
    /// has to sit and watch. Neither half of that argument holds here, because there is no worktree
    /// and because the owner is by definition sitting in front of this conversation.
    ///
    /// `acceptEdits` would be no better and is not the middle ground it sounds like: there is no
    /// worktree for an accepted edit to be in, so what it accepts is edits anywhere the agent can
    /// reach. So the mode is the one that asks, and the composer still offers the other three for
    /// the day somebody wants one. `ComposerDefaults.resolve` is what stops the owner's default
    /// landing on this chat the first time it is opened.
    public static let permissionMode = PermissionMode.auto

    /// The chat's working directory: its own, empty, and made once.
    ///
    /// **This is a permission decision rather than a tidiness one**, and it is the second lock
    /// rather than the first. `permissionMode` above is what stops this chat opening on the mode
    /// the owner's other chats open on; this is what makes the mode it does open on mean something.
    /// A chat started in the owner's home directory would treat every file in it as inside the
    /// working directory, which is the one place a mode stops asking about. An empty directory of
    /// its own makes every filesystem reach a reach *outside* it, which is a reach that asks, and
    /// it pushes the agent towards the bridge tools instead, which are the audited surface.
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
