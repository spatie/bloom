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
    ///
    /// It stays empty of anything the owner did not put there, rather than empty for ever, and
    /// that is the honest reading of the paragraph above. Attaching a file to a prompt copies it
    /// under `.bloom/attachments` here, exactly as it would in a worktree, and the agent can then
    /// read it without asking. That is not a hole, it is what attaching a file means: the reach
    /// the mode is protecting is the one nobody made on purpose.
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

    /// What this conversation opens on, given the mode its row was last left holding.
    ///
    /// Nil means leave the row alone.
    ///
    /// **The lock has to be reapplied, or it holds exactly once.** `ComposerDefaults.resolve`
    /// settles a chat's mode the first time it is opened and never again, and the composer's
    /// picker writes the owner's choice onto the row. So a Full access chosen once to get
    /// something done would have been what this conversation opened on for ever after, which is
    /// the state the mode exists to prevent, arrived at quietly.
    ///
    /// The answer is not to take the picker away. A mode chosen mid-conversation was chosen by
    /// somebody sitting in front of the conversation with the facts on the screen, and overruling
    /// that while they watch would be a control that does not work. What expires is not the choice
    /// but the presence behind it: a launch later, the agent that choice was made for is gone and
    /// so is the memory of making it, and the mode would go on governing everything asked
    /// tomorrow. This is the same reasoning `Store.resetRunningSessions` and
    /// `abandonPendingPermissionAsks` are built on, which is that a launch boundary ends what a
    /// person's presence justified.
    ///
    /// So: honoured for the rest of the launch, back to Ask on the next one, and the permission
    /// menu's own footnote says so before the choice is made. See
    /// `ComposerControls.missingPermissionModeNote`.
    public static func modeOnOpening(
        stored: PermissionMode,
        isFirstOpenSinceLaunch: Bool
    ) -> PermissionMode? {
        guard isFirstOpenSinceLaunch, stored != permissionMode else { return nil }
        return permissionMode
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
    ///
    /// **It used to lead with what this chat cannot do.** "This chat has no worktree. ... It
    /// cannot change a file." Both sentences are true and neither belongs on the first screen: a
    /// worktree is Bloom's word for a thing the reader has not met yet, and an empty pane that
    /// opens by listing its own limits reads as an apology for existing. The limits are real and
    /// they are said where they change a decision, which is the permission menu's footnote.
    ///
    /// So this says what to ask it for, in the order somebody would want it: start something, find
    /// out where everything stands, then go to the thing you found.
    public static let emptyHeading = "Ask Bloom anything about your work"
    public static let emptyDetail =
        "Start a new project or a workspace, ask what is running and what needs you, "
        + "find the workspace with the failing checks, and open it."
}
