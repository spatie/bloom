import Foundation

/// Whether a stored row is going to draw anything at all, answered from the row rather than from a
/// laid out view.
///
/// **Sixty per cent of a real session draws nothing.** Measured on an 1,855 row conversation and
/// again on a 2,981 row one: 1,804 of the latter are `system` stream events, and most `system` rows
/// draw no view at all. They are ordinary rows in the table, three to five of
/// them between every pair of tool calls, and until something has drawn one there is nothing to
/// tell the table but the running mean of the rows that HAVE been drawn.
///
/// That is what put a hundred points of blank between two one line Bash rows, and the correction
/// for it is what makes scrolling upwards expensive: a screen of rows nobody has drawn is a screen
/// of guesses, every one of which is put right a frame later and moves everything below it. The
/// guess can simply be right instead. See `TranscriptRowHeights.assumed`.
///
/// **A sniff rather than a decode, for the reason `TranscriptNoise` gives.** Deciding this by
/// decoding the payload would be the whole cost this exists to avoid, once per row on the pass
/// that assembles the entries. The first bytes are enough to tell the two apart.
///
/// It is a claim about what the row will draw, not a promise. A row that draws something after all
/// reports its height when it is drawn and is corrected then, exactly as any other estimate is, so
/// being wrong here costs one correction rather than a wrong transcript.
public enum TranscriptRowInk {
    /// How far into a payload the marker is looked for. The type and the subtype are the first two
    /// fields the CLI writes, so this is generous rather than tight.
    private static let probeLength = 256

    /// What an init row's payload says and no other system row's does.
    ///
    /// The closing quote is deliberately not part of it. A subtype that merely STARTS with `init`
    /// is then read as an init and drawn from the mean, which is what every row does today;
    /// spelling the quote and missing a real init would draw a visible row at nothing until it
    /// reported. Of the two ways to be wrong, this is the one that costs nothing.
    private static let initMarker = Data("\"subtype\":\"init".utf8)
    private static let streamEventPrefix = Data("{\"type\":\"stream_event\"".utf8)
    /// Stored system events that `TranscriptRowView` never renders. Require the two top-level
    /// fields in their wire order, so a nested mention of a subtype cannot silence a row.
    private static let silentSystemPrefixes = [
        Data("{\"type\":\"system\",\"subtype\":\"task_progress\"".utf8),
        Data("{\"type\":\"system\",\"subtype\":\"background_tasks_changed\"".utf8),
        Data("{\"type\":\"system\",\"subtype\":\"vcs_state_changed\"".utf8),
        Data("{\"type\":\"system\",\"subtype\":\"commands_changed\"".utf8),
    ]

    /// A stream delta is never rendered from its stored row. `AgentEvent.decodeStreamEvent`
    /// produces only live deltas or an unknown event, and the system row renderer accepts neither.
    /// Require the exact top-level prefix: an unfamiliar payload stays eligible for measurement.
    public static func isStreamEvent(kind: MessageKind, payload: Data) -> Bool {
        kind == .system && payload.starts(with: streamEventPrefix)
    }

    /// Rows whose zero height can be stored without constructing a hosting view. The broader
    /// `drawsNothing` below is an estimate and still needs a chance to correct itself.
    public static func isDefinitelySilent(kind: MessageKind, payload: Data) -> Bool {
        guard kind == .system else { return false }
        return payload.starts(with: streamEventPrefix)
            || silentSystemPrefixes.contains { payload.starts(with: $0) }
    }

    public static func isSessionStart(kind: MessageKind, payload: Data) -> Bool {
        kind == .system && payload.prefix(probeLength).range(of: initMarker) != nil
    }

    /// Whether this row is expected to draw nothing at all.
    ///
    /// Only `system` is answered. Every other kind draws something often enough that a claim about
    /// it would be a guess, and a guess here is worth less than the mean it would replace. A tool
    /// result whose call is on the row above draws nothing either, but which rows those are is a
    /// question about the row before it rather than about the row, so it is not answered here.
    ///
    /// A background task's notification and a compaction boundary draw. Session init metadata
    /// stays stored, but it no longer gets a line in the transcript.
    public static func drawsNothing(kind: MessageKind, payload: Data) -> Bool {
        guard kind == .system else { return false }
        return !BackgroundWake.isRow(kind: kind, payload: payload)
            && !ContextCompaction.isRow(kind: kind, payload: payload)
    }
}
