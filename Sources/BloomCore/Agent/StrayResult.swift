import Foundation

/// A `result` line that closes a turn nobody in Bloom asked for.
///
/// **The bug: a turn that started and ended in a tenth of a second having done nothing.** The
/// owner pressed Commit and push. The transcript drew his prompt, then "Session started", then
/// "0,1s", and after that no tool call, no prose and no error. He pressed the button again. The
/// second press landed in a turn that was, by then, genuinely working, so his prompt was injected
/// into the middle of a turn: the one thing the delivery queue exists to prevent.
///
/// His database holds the whole explanation. One process launch, and then two `init` lines five
/// milliseconds apart with a `result` wedged between them:
///
///     {"type":"system","subtype":"init",...}
///     {"type":"result","subtype":"success","num_turns":0,"duration_api_ms":0,"result":"",
///      "origin":{"kind":"task-notification"},"duration_ms":60,...}
///     {"type":"system","subtype":"init",...}
///
/// The CLI had a background task notification waiting for it from hours earlier. `--resume`
/// brought the session back, the CLI ran that notification as a turn of its own before it read
/// anything from stdin, decided there was nothing to do, and said so in sixty milliseconds. Then
/// it started the owner's turn, which is the second `init`.
///
/// Bloom read that `result` because every `result` used to end whatever turn was open. It wrote
/// the footer, put sixty milliseconds under it, cleared `isRunning`, told the sidebar the
/// workspace was idle and drained the queue, all while the owner's turn was still starting. The
/// same pair of lines is in the database twice, from two different workspaces on the same day, so
/// it is a shape rather than a one-off.
///
/// Here rather than in the runner because it is a decision about whose turn a line belongs to,
/// and the test target cannot see a view or launch a CLI.
public enum StrayResult {
    /// Whether this line closes a turn Bloom never started.
    ///
    /// **Two facts have to agree, and needing both is the point.** The origin is the CLI saying
    /// where the turn came from, and every result an owner's prompt has ever produced in this
    /// database names none at all, so a stated origin is somebody else's turn by construction.
    /// Testing for the absence rather than for the literal `task-notification` is what keeps this
    /// working when the CLI invents a second kind, or renames this one.
    ///
    /// The emptiness is the net under that reading. No turn Bloom sent comes back with no API
    /// time, no iterations, nothing said and no error, so nothing this ignores was ever an answer
    /// to a prompt. Ignoring a real result would leave the composer reading "Working" until the
    /// process exited, and trading this bug for that one is not a fix.
    public static func isStray(_ result: AgentResult) -> Bool {
        !result.origin.isEmpty && didNothing(result)
    }

    /// A turn that reached no model, ran no tool, said nothing and did not fail.
    private static func didNothing(_ result: AgentResult) -> Bool {
        !result.isError
            && result.numTurns == 0
            && result.durationAPIMS == 0
            && result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
