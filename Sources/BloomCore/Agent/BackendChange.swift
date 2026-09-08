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

    /// Whether a chat has anything on it that belongs to the backend it is on.
    ///
    /// **Not `rows.isEmpty` on its own, and that is the bug this exists for.** A transcript reads
    /// its history off SQLite asynchronously, so a chat opened a moment ago has no rows yet and is
    /// not an empty chat: it is a chat nobody has read. A picker press in that window read the
    /// empty list as "nothing to strand" and changed the chat in place, which left a Claude Code
    /// `agentSessionID` on a row a Codex runner was about to resume from, and Codex has never
    /// heard of that id.
    ///
    /// Three answers, asked in this order, and the order is the design:
    ///
    /// 1. **A thread id is proof, and it needs no read.** It names a conversation on one CLI's
    ///    server and it is a column on the session row. `ComposerView.repairModel` already asks
    ///    this and only this, for the same reason.
    /// 2. **A row on screen is proof.** A turn that has been spoken is written in one CLI's
    ///    vocabulary whether or not the thread id has come back yet, which is the state a chat is
    ///    in for the whole of its first turn.
    /// 3. **Otherwise only a transcript that has finished reading may answer no.** One that has
    ///    not does not know, and the two mistakes do not cost the same: a needless fork is a tab
    ///    somebody closes, and a wrong change in place strands a conversation.
    public static func hasSpoken(
        rowCount: Int,
        agentSessionID: String?,
        isTranscriptLoaded: Bool
    ) -> Bool {
        if !(agentSessionID ?? "").isEmpty { return true }
        if rowCount > 0 { return true }
        return !isTranscriptLoaded
    }

    /// What the window says when a chat forked rather than changed.
    ///
    /// **A fork nobody is shown is indistinguishable from a picker that does nothing**, and that
    /// is what was reported: a chat on Sonnet 5 was pointed at a Codex model, the menu was
    /// dismissed, a chat was made somewhere off screen, and the composer went on saying Sonnet 5.
    /// The new chat is brought to the front now, and this is the sentence that says why the
    /// conversation the user was looking at is not the one in front of them any more.
    ///
    /// One sentence of fact and one of reason, which is the shape `NoticeText` splits on.
    public static func forkNotice(title: String, from current: AgentKind) -> String {
        "Opened `\(title)` and brought it to the front. A conversation keeps the backend it "
            + "started on, so the \(current.label) one is still there with its transcript and its "
            + "thread untouched."
    }

    /// And when the fork could not be made at all.
    ///
    /// The same argument as `forkNotice` from the other side: a press that produced nothing is a
    /// picker that appears broken, and the one state this really happens in, a workspace being
    /// archived out from under the window, is exactly the one where the user needs telling.
    public static func forkFailureNotice(to wanted: AgentKind) -> String {
        "Could not open a \(wanted.label) conversation here. This conversation is unchanged, so "
            + "nothing has been lost, and the workspace may be on its way to the archive."
    }

    /// The same news for the one chat that has no tab strip to fork into.
    ///
    /// Ask Bloom sits above every project, so there is no second tab beside it. Its equivalent of
    /// a fork is a fresh conversation with the old one archived, and archived is not deleted: what
    /// was said is still in the database. That is worth a sentence, because the transcript on
    /// screen does visibly empty.
    public static func replacementNotice(from current: AgentKind, to wanted: AgentKind) -> String {
        "Started a fresh conversation on \(wanted.label). Ask Bloom has no second tab to fork "
            + "into, so the \(current.label) one was archived rather than changed, and nothing "
            + "said in it is lost."
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
