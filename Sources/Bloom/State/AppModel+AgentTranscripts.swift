import Foundation
import BloomCore

/// The agent CLIs' own transcripts for an archived workspace, which a permanent delete takes too.
///
/// The finding and every rule about what may be taken is `AgentTranscriptFiles` in the core, the
/// same code a Bloom Server runs, so the Mac and the server cannot disagree about which file
/// belongs to a worktree. What is here is only where the answers come from on this Mac: the
/// store's threads and this account's home. The walk is detached because `~/.codex/sessions`
/// holds a file per Codex thread ever run, and listing it is not work for the main actor.
extension AppModel {
    /// What the CLIs kept for each of `ids` that is still archived, found before the rows go.
    func agentTranscripts(forDeleting ids: [WorkspaceID]) async -> [AgentTranscriptFiles] {
        guard let store, let keeping = try? await store.agentThreadIDs(outside: ids) else { return [] }
        var plans: [AgentTranscriptFiles] = []
        for id in ids {
            guard let workspace = try? await store.workspace(id: id), workspace.state == .archived,
                  let threads = try? await store.agentThreads(workspaceID: id) else { continue }
            plans.append(await Self.find(worktree: workspace.path, threads: threads, keeping: keeping))
        }
        return plans
    }

    /// The lines the delete confirmation adds for them.
    func agentTranscriptLosses(for workspace: Workspace) async -> [String] {
        await agentTranscripts(forDeleting: [workspace.id]).compactMap(\.loss)
    }

    private static func find(worktree: String, threads: [AgentThread], keeping: Set<String>) async -> AgentTranscriptFiles {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return await Task.detached {
            AgentTranscriptFiles.find(worktree: worktree, threads: threads, keeping: keeping, home: home)
        }.value
    }
}
