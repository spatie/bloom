import Foundation

/// Whether a row under a workspace is an agent, or a shell command the CLI put in the background.
///
/// **Two different things arrive on the same four lines, and Bloom had been drawing them as one.**
/// `system/task_started` is sent for a Task subagent and for a backgrounded Bash command alike,
/// and `task_type` is the only field that tells them apart. Measured across the transcripts on
/// this machine: 13 lines say `local_agent` and 65 say `local_bash`, so the common case was the
/// one nothing was written for.
///
/// The shapes differ, not just the label. A `local_agent` start carries `subagent_type`,
/// `spawn_depth`, `is_backgrounded` and the whole `prompt`. A `local_bash` start carries
/// `task_id`, `tool_use_id`, `description` and `task_type` and **nothing else**: no type, no
/// depth, no prompt. That is why a background command's pane read
///
///     Build frontend assets
///     subagent
///     Background command "Build frontend assets" completed (exit code 0)
///
/// The word "subagent" there is `SubagentOutputView`'s fallback for an absent `subagent_type`, and
/// the missing body is `SubagentTranscript` parsing a plain stdout capture as NDJSON and finding
/// no lines it recognises. Both are the same bug: an agent's questions asked of something that is
/// not one.
public enum SubagentKind: Sendable, Hashable, CaseIterable {
    /// A Task subagent. It was given a prompt and it wrote its own transcript.
    case agent
    /// A shell command running in the background. It has a command line and stdout.
    case command

    /// The one word the CLI uses for a backgrounded shell command.
    ///
    /// Matched exactly rather than by prefix or by "contains bash": an unknown `task_type` is
    /// treated as an agent, because an agent's pane degrades to a title and a summary when a
    /// field is missing while a command's pane would claim a command line that does not exist.
    static let commandTaskType = "local_bash"

    public init(taskType: String) {
        self = taskType == Self.commandTaskType ? .command : .agent
    }

    /// What this is called in a sentence, in the pane's subtitle and out loud to a screen reader.
    public var noun: String {
        switch self {
        case .agent: "subagent"
        case .command: "background command"
        }
    }

    /// Whether its output file is NDJSON in Claude Code's transcript shape, or plain stdout.
    ///
    /// The whole reason the distinction is carried this far. An agent's `output_file` is a symlink
    /// to `subagents/agent-<task_id>.jsonl`; a command's is `tasks/<task_id>.output`, which is
    /// bytes a program printed and has no structure at all.
    public var writesTranscript: Bool { self == .agent }
}
