import Foundation

/// Where the Agent call row in the chat takes the reader, and whether it can take them anywhere.
///
/// **The gap this closes.** The chat takes a subagent's rows out of the list and lets the call
/// that started it stand for them (see `TranscriptFold`). That is only safe if the call row leads
/// to the run, and nothing in the chat did: the detail pane was reached from the sidebar alone,
/// `SubagentRetention` takes a successful subagent's sidebar row away seconds after it finishes,
/// `SubagentRoster.turnStarted` forgets it when the next turn starts, and a relaunch forgets every
/// one. A finished subagent's work was unreachable from the chat, which was reported as the
/// regression it is.
///
/// **So the identity is the call's own `tool_use_id`, which is on the stored row and outlives all
/// three.** Every line the subagent produced was stored carrying that id as its
/// `parent_tool_use_id`, and `SubagentTranscript.live` already reads a run back out of those rows:
/// it is what the pane shows for a running subagent before the CLI names its file. The roster is
/// still preferred while it holds the subagent, because it knows more (the CLI's file, its
/// summary, a Codex thread). When it does not, the stored rows are the run.
///
/// **A run with nothing stored under it says so rather than opening.** A pane with a title and
/// nothing under it is a click that answers nothing, and the call row is the one place that can
/// say so before anybody clicks.
public enum SubagentRunLink {
    /// What opening an Agent call row opens.
    public enum Target: Hashable, Sendable {
        /// The roster still holds the subagent, so the pane the sidebar row opens.
        case live(SubagentID)
        /// The run read back from the rows stored under the call.
        case recorded(toolUseID: String)
        /// Nothing of the run was kept to open.
        case unavailable
    }

    public static let openHelp = "Open this agent's run"
    public static let openActionName = "Open run"
    /// Said on the row in the place the count goes, after the meta separator.
    public static let unavailableLabel = "run not kept"
    public static let unavailableHelp = "Bloom kept nothing of this agent's run, so there is nothing to open."

    /// Whether a tool call starts a subagent. The two names Claude Code has used for it, and the
    /// one `GrokTranslation` maps its own spawn onto.
    public static func isAgentCall(toolName: String) -> Bool {
        toolName == "Task" || toolName == "Agent"
    }

    /// What clicking the call row opens.
    ///
    /// - Parameters:
    ///   - hasRecordedRows: whether any row is stored under this call, which is
    ///     `TranscriptFold.Folds.hasRun(underCall:)`.
    ///   - isSettled: whether the call's result has come back. A call still waiting is a run in
    ///     progress whose first row may simply not have landed, so it opens on the rows as they
    ///     arrive rather than being called lost.
    ///   - liveID: the roster's subagent for this call. Asked first, because the roster knows more
    ///     than the stored rows do while it still holds the subagent.
    public static func target(
        toolUseID: String?,
        hasRecordedRows: Bool,
        isSettled: Bool,
        liveID: () -> SubagentID?
    ) -> Target {
        guard let toolUseID, !toolUseID.isEmpty else { return .unavailable }
        if let id = liveID() { return .live(id) }
        return hasRecordedRows || !isSettled ? .recorded(toolUseID: toolUseID) : .unavailable
    }

    /// Whether the row offers to open anything, which is `target` not being `.unavailable`.
    ///
    /// **Its own function, with the roster asked LAST, and that is the transcript's performance
    /// rule.** The roster moves about once a second while a subagent works, and every row that
    /// reads it redraws when it does. Asked first, every Agent call row in the conversation would
    /// be woken by every tick; asked last, only a finished call with nothing stored under it ever
    /// reads it, which is the rare row.
    public static func canOpen(
        toolUseID: String?,
        hasRecordedRows: Bool,
        isSettled: Bool,
        isLive: (String) -> Bool
    ) -> Bool {
        guard let toolUseID, !toolUseID.isEmpty else { return false }
        return hasRecordedRows || !isSettled || isLive(toolUseID)
    }

    /// A subagent rebuilt from the call that started it, for a pane the roster can no longer
    /// describe.
    ///
    /// Everything the pane's header says is on the call: the description, the type and the brief
    /// are its input, and whether it is running, failed or done is whether its result has come
    /// back and what that said. The id is the call's own, which is never compared with a roster
    /// id: it only names the pane.
    ///
    /// - Parameter input: the call's decoded input, or nil when it could not be read, which still
    ///   leaves a pane that reads the stored rows under a generic title.
    public static func recordedSubagent(
        toolUseID: String,
        input: JSONValue?,
        startedAt: Date,
        isSettled: Bool,
        failed: Bool,
        durationMS: Int?
    ) -> Subagent {
        let state: SubagentState = !isSettled ? .running : (failed ? .failed : .completed)
        let seconds = (durationMS ?? 0) / 1_000
        return Subagent(
            id: SubagentID(toolUseID),
            toolUseID: toolUseID,
            description: input?["description"]?.stringValue ?? "",
            type: input?["subagent_type"]?.stringValue ?? "",
            prompt: input?["prompt"]?.stringValue ?? "",
            taskType: "local_agent",
            state: state,
            elapsedSeconds: seconds,
            finishedAt: isSettled ? startedAt.addingTimeInterval(Double(seconds)) : nil,
            startedAt: startedAt
        )
    }
}
