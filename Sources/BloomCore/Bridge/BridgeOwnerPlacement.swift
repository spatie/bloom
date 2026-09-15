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
public enum BridgeOwnerPlacement {
    /// The refusal for an owner's token presented from `workingDirectory`, or nil when that
    /// directory is in no live workspace. Nil as well when the directory could not be read,
    /// because failing to see where a caller is is not evidence that it is somewhere it should not
    /// be, and the owner's own terminal breaking over a syscall would be the worse outcome.
    public static func refusal(workingDirectory: String?, workspaces: [Workspace]) -> String? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        let directory = standardised(workingDirectory)
        guard let workspace = workspaces.first(where: { workspace in
            guard workspace.state != .archived, !workspace.path.isEmpty else { return false }
            let root = standardised(workspace.path)
            return directory == root || directory.hasPrefix(root + "/")
        }) else { return nil }

        return """
            This is the owner's own registration of Bloom, and it was started inside the Bloom \
            workspace '\(workspace.name)' at \(workspace.path). An agent working in a workspace \
            uses the bridge Bloom gives that workspace, not the owner's, so this connection was \
            refused. To use the owner's tools, run the client from a directory outside Bloom's \
            workspaces.
            """
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
