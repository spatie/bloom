import Foundation

/// Whether the owner's token is being presented from inside a workspace, and the sentence that
/// refuses it if so.
///
/// ## The leak this closes
///
/// The owner registers Bloom in their own `~/.claude.json` at user scope, and Claude Code applies
/// user scope to every session on the machine, including every session Bloom launches. So every
/// workspace agent ran two shims: its own, on its session token, and the owner's, on the standalone
/// token. Measured with `lsof` on 15 September 2026: each Bloom-launched `claude` had one of each,
/// and an agent in a workspace another agent had started, then penned in as a child, called
/// `workspace_archive` through the owner's shim instead. The only thing that stopped it was the
/// safety check noticing that its own turn was still running. `BridgeRegistration.serverName`
/// had already given the two different names so that neither would shadow the other, which kept
/// the registrations apart and did nothing about an agent holding both.
///
/// ## Why the working directory is the test
///
/// The same measurement showed how to tell them apart. A CLI starts its stdio MCP servers in its
/// own working directory, and Bloom starts a workspace agent in the worktree, so an owner shim run
/// by a workspace agent has a worktree as its working directory. Ask Bloom's shim, which really is
/// the owner, runs in `Application Support/Bloom/Ask`, and a terminal the owner opened anywhere
/// else is anywhere else. The environment would have been the obvious signal and is the wrong
/// one: Codex hands an MCP server a short allow list of variables rather than its own environment,
/// so a marker Bloom set on the agent would never reach the shim.
///
/// This is not a security boundary and must not be commented as one. The token is readable by
/// anything running as the user, as `BridgeProtocol.tokenVariable` says, and an agent that wants
/// the owner's tools badly enough can start the shim from another directory. What it stops is the
/// ordinary case, which is an agent that has the owner's tools simply because a config file was
/// read. The owner running their own `claude` inside a worktree is refused too, and the sentence
/// says why and what to do, because that client is standing in a workspace just as surely.
///
/// ## The project's own checkout
///
/// A project checkout workspace sits at the project's root, which is also where the owner opens a
/// terminal and runs their own `claude`, so the directory alone would refuse the owner in their
/// own project for as long as that workspace is live. The directory alone cannot let them through
/// either: every agent Bloom starts in that workspace stands in the same folder and runs the
/// owner's shim too. What tells them apart is who started the process. Bloom's agents are its own
/// children, or children of its private tmux server for a chat in a terminal; the owner's
/// Terminal or iTerm is neither. So a caller inside a project checkout is asked about its lineage
/// and let through only when it does not come from Bloom. A terminal pane inside Bloom comes from
/// Bloom's tmux server as well and is refused like any other workspace, which is the same answer
/// it gets in a worktree.
public enum BridgeOwnerPlacement {
    /// The refusal for an owner's token presented from `workingDirectory`, or nil when that
    /// directory is in no live workspace. Nil as well when the directory could not be read,
    /// because failing to see where a caller is is not evidence that it is somewhere it should not
    /// be, and the owner's own terminal breaking over a syscall would be the worse outcome.
    ///
    /// - Parameter descendsFromBloom: whether the caller was started by this app, asked only when
    ///   `needsLineage` says the answer matters. Nil when it was not asked or could not be read,
    ///   which keeps the refusal: inside a project checkout that is what the answer was before the
    ///   carve-out, and a `ps` that failed is no evidence that an agent is the owner.
    public static func refusal(
        workingDirectory: String?, workspaces: [Workspace], descendsFromBloom: Bool? = nil
    ) -> String? {
        guard let workspace = standing(in: workingDirectory, among: workspaces) else { return nil }
        if workspace.kind == .projectCheckout {
            // Only a lineage read as "not Bloom's" is let through. True and unread both refuse.
            if descendsFromBloom != false {
                return """
                    This is the owner's own registration of Bloom, and it was started by Bloom \
                    inside the project checkout '\(workspace.name)' at \(workspace.path). An agent \
                    working there uses the bridge Bloom gives that workspace, not the owner's, so \
                    this connection was refused. To use the owner's tools in this folder, run the \
                    client from a terminal outside Bloom.
                    """
            }
            return nil
        }

        return """
            This is the owner's own registration of Bloom, and it was started inside the Bloom \
            workspace '\(workspace.name)' at \(workspace.path). An agent working in a workspace \
            uses the bridge Bloom gives that workspace, not the owner's, so this connection was \
            refused. To use the owner's tools, run the client from a directory outside Bloom's \
            workspaces.
            """
    }

    /// Whether the caller's lineage has to be read before `refusal` can answer, which is only
    /// when the directory is inside a live project checkout. Asked first so that `ps` runs for
    /// that one case and never for the owner's terminal anywhere else.
    public static func needsLineage(workingDirectory: String?, workspaces: [Workspace]) -> Bool {
        standing(in: workingDirectory, among: workspaces)?.kind == .projectCheckout
    }

    /// The live workspace `workingDirectory` is inside, if any. The deepest one wins, so a
    /// worktree kept under the project's own folder is still that worktree rather than the
    /// project checkout around it.
    private static func standing(in workingDirectory: String?, among workspaces: [Workspace]) -> Workspace? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        let directory = standardised(workingDirectory)
        return workspaces
            .filter { workspace in
                guard workspace.state != .archived, !workspace.path.isEmpty else { return false }
                let root = standardised(workspace.path)
                return directory == root || directory.hasPrefix(root + "/")
            }
            .max { standardised($0.path).count < standardised($1.path).count }
    }

    /// Without a trailing slash or `.` components, so `/a/b/` and `/a/b` are one directory and
    /// `/a/bc` is not inside `/a/b`. Symlinks are resolved as well, because the kernel reports the
    /// real directory and a workspace recorded through a link would otherwise never match; a path
    /// that does not exist resolves to itself.
    private static func standardised(_ path: String) -> String {
        let standard = (path as NSString).resolvingSymlinksInPath
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}
