import Foundation

/// A run whose process is gone while the turn it was serving is still open, and the row that says
/// so.
///
/// **The bug: "sometimes the AI just stops dead in the water".** The owner's transcript ended on a
/// tool call with no result under it, no prose after it, no error row and no footer, while the
/// status bar went on counting the turn as one of three running. His database holds the whole of
/// it. Four `claude` children fell silent between 11:10:31 and 11:11:06 on 26 August 2026, every
/// one of them in the middle of a turn, and every one of those transcripts ends on a
/// `content_block_start` stream event with nothing after it until he typed again ten minutes
/// later. `ps` says the children serving those sessions started at 11:17:28 and 11:21:29, which is
/// when he typed, so the processes he was waiting on had exited long before. Not one `.error` row
/// exists anywhere in that database.
///
/// That last fact is the fault, and it is one line of `AgentRunner`. A run that ended was only
/// worth a row when its exit status said something had gone wrong: `if status != 0, !sawResult`.
/// A CLI that exits **cleanly** in the middle of a turn took the quiet branch instead, moved the
/// session to `idle`, and yielded nothing at all to the event sink. Nothing therefore reached
/// `TranscriptModel`, so `isRunning` stayed true for the rest of the launch, the composer kept its
/// working state, the subagent roster was never told the turn had ended, and the sidebar, the Dock
/// badge and the status bar all went on counting a turn that had no process behind it.
///
/// So the test is no longer the exit status. **It is whether a turn was open when the process
/// went away**, which is a question the session's own state machine already answers, and which is
/// right for the two cases the old rule also missed: a run that served an earlier turn
/// successfully and then died during a later one, where `sawResult` is stale and true; and a turn
/// blocked on a permission question, where the pipe closing means the question can never be
/// answered.
///
/// Here rather than in the runner because it is a decision about what an ending means and what it
/// is worth saying, and the test target cannot launch a CLI. See `AgentExit` for the words the row
/// draws, and `SessionLifecycle` for why `processFailed` rather than `processExited`.
public struct UnfinishedRun: Sendable, Hashable {
    /// What the process exited with. Kept even when it is zero, because a clean status is part of
    /// the account rather than a reason to say nothing.
    public let status: Int32
    /// The tail of what the CLI wrote to stderr, whole.
    public let stderr: String
    /// The resolved path of what was launched, so a row can name the binary rather than the name
    /// it was asked for.
    public let command: String
    /// Whether a turn was open at the moment the process went away.
    public let leftATurnOpen: Bool

    public init(status: Int32, stderr: String, command: String, leftATurnOpen: Bool) {
        self.status = status
        self.stderr = stderr
        self.command = command
        self.leftATurnOpen = leftATurnOpen
    }

    /// What a finished run owes the transcript, or nothing when it owes it nothing.
    ///
    /// - Parameter state: the session's state at the moment the process went away, which is what
    ///   says whether a turn was open. A `result` has already moved it off `running` by the time
    ///   this is asked, because both run on the same actor and the read loop drains before the
    ///   process is reaped.
    /// - Parameter sawResult: whether this run reported at least one result of its own. Only used
    ///   for the second rule below, where there is no open turn to reason about.
    public static func of(
        status: Int32,
        sawResult: Bool,
        state: SessionState,
        stderr: String,
        command: String
    ) -> UnfinishedRun? {
        if state.isMidTurn {
            return UnfinishedRun(status: status, stderr: stderr, command: command, leftATurnOpen: true)
        }
        // The rule this type was grown from, kept for the case it was written for: a CLI that
        // falls over between turns, having reported nothing, is still worth a row even though
        // there is no turn hanging on it.
        guard status != 0, !sawResult else { return nil }
        return UnfinishedRun(status: status, stderr: stderr, command: command, leftATurnOpen: false)
    }

    /// Whether the exit gave any account of itself at all.
    ///
    /// A non-zero status is an account, and so is anything on stderr. Neither, in the middle of a
    /// turn, is the silence this type is named for, and it gets its own words rather than being
    /// reported as "Agent exited (0)", which reads as nothing being wrong.
    public var wasSilent: Bool {
        leftATurnOpen && status == 0 && stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the payload's `subtype` says, which is what `AgentExit.read` reads it back as.
    public var subtype: String { wasSilent ? Self.abandonedSubtype : Self.exitSubtype }

    /// The one string both ends agree on, so the writer and the reader cannot drift apart.
    public static let abandonedSubtype = "turn_abandoned"
    public static let exitSubtype = "process_exit"

    /// The `.error` event's message, which is what the alert and the notification say.
    public var message: String {
        guard !wasSilent else { return Self.silentSentence }
        let opening = "The agent exited with status \(status)."
        let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? opening : "\(opening)\n\(stderr)"
    }

    /// Said in the same register as `AgentExit.advice`, and for the same worry: what a person
    /// wants to know the moment a turn stops is whether their work survived.
    public static let silentSentence = "The agent's process ended in the middle of this turn."

    /// The stored `.error` row.
    ///
    /// Built here rather than in the runner so the shape `AgentExit.read` decodes is written in
    /// one place. Encoding a struct of two strings and two numbers cannot fail, and the fallback
    /// exists so that a turn which ended badly cannot also end silently.
    public var payload: Data {
        (try? JSONEncoder().encode(Stored(
            subtype: subtype, status: Int(status), stderr: stderr, command: command
        ))) ?? Data(#"{"type":"error"}"#.utf8)
    }

    private struct Stored: Encodable {
        let type = "error"
        let subtype: String
        let status: Int
        let stderr: String
        let command: String
    }
}
