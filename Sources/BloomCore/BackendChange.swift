import Foundation

/// What picking a different agent for a chat has to do.
///
/// Borrowed from Conductor, and it is the right rule for a reason that is not policy: a chat's
/// rows are written in its backend's vocabulary, its `agentSessionID` names a thread on that
/// backend's server, and its context lives there too. Turning a chat that has already spoken into
/// a chat on the other backend would leave a transcript half in one vocabulary and half in the
/// other, and a resume that resumes nothing.
///
/// So a chat that has spoken **forks**: a new chat beside it, in the same workspace, on the same
/// worktree and the same branch, carrying the same defaults. Nothing is lost, nothing is
/// stranded, and the conversation that exists stays the thing it is. A chat with no messages yet
/// simply changes, because there is nothing there to strand.
///
/// Pure and in the core so the rule can be asserted on without a window.
public enum BackendChange: Sendable, Equatable {
    /// Already on that backend. Nothing to do, and in particular nothing to fork: pressing the
    /// entry a chat is already on must not make a second chat.
    case unchanged
    /// The chat has not spoken yet, so it can simply become a chat on the other backend.
    case changeInPlace(AgentKind)
    /// The chat has a transcript. A new one is made beside it.
    case fork(AgentKind)

    public static func decide(from current: AgentKind, to wanted: AgentKind, hasSpoken: Bool) -> BackendChange {
        guard current != wanted else { return .unchanged }
        // A backend with no runner is not a destination. `AgentKind.canRunWorkspaces` is what the
        // picker filters on, and this is the same answer from the other side, so a stale menu or
        // a deep link cannot put a chat on something that cannot run it.
        guard wanted.canRunWorkspaces else { return .unchanged }
        return hasSpoken ? .fork(wanted) : .changeInPlace(wanted)
    }

    /// What a chat forked onto another backend is called, so the strip does not show two tabs with
    /// the same name and no way to tell them apart.
    public static func forkedTitle(_ title: String, to kind: AgentKind) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "New session" : trimmed
        // Not accumulated. Forking twice must not read "Fix the parser on Codex on Claude Code".
        let stem = base.components(separatedBy: " on ").first ?? base
        return "\(stem) on \(kind.label)"
    }
}
