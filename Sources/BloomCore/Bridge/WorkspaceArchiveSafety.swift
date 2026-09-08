import Foundation

/// Whether a workspace can be taken off disk right now, asked in the two places that have to agree.
///
/// The owner's own client asks once, and once is enough: it is standing outside every turn, so
/// nothing it can see is about to change between the question and the archive. A workspace's own
/// agent asks twice, and that is the whole reason this is a type rather than a paragraph inside
/// `WorkspaceArchiveTool`. The first ask is made while the asking turn is still running, so the
/// caller's own chat is excused; the second is made once that turn has ended, with nothing
/// excused, and it is the one that decides. Written out twice it would be edited once, and the
/// half nobody edited would be the half that runs after the agent has stopped watching.
public enum WorkspaceArchiveSafety {
    /// The sentence to refuse with, or nil when nothing objects.
    ///
    /// `excusing` is the chat that is doing the asking. Its own `running` is the call in flight
    /// rather than work at risk, so it is not an objection. Everything else about it still is, and
    /// its queue in particular: a message waiting to go is something the owner asked for, and
    /// archiving over it would throw it away without ever having shown it to an agent.
    public static func objection(
        to workspace: Workspace,
        excusing asking: SessionID?,
        store: Store
    ) async -> String? {
        if workspace.setupState == .running {
            return "Workspace setup is still running. Wait for it to finish before archiving."
        }
        do {
            for session in try await store.sessions(workspaceID: workspace.id) {
                if session.id != asking, session.state == .running || session.state == .waiting {
                    return """
                        An agent is running or awaiting an answer in this workspace. Finish or \
                        stop it before archiving.
                        """
                }
                if try await !store.pendingDeliveries(sessionID: session.id).isEmpty {
                    return "This workspace has queued messages. Handle them before archiving."
                }
            }
        } catch {
            return "Bloom could not check this workspace's activity. Nothing was archived; try again shortly."
        }
        return nil
    }
}
