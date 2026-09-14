import Foundation

/// The line that opens a turn nobody in Bloom sent: a background task finishing.
///
/// **The bug: work carrying on under a footer that said the turn was over.** The owner merged a
/// pull request, the turn closed with "Completed in 21s", and under that footer came seventeen
/// actions and a second answer with nothing above them. The agent had put a CI watch in the
/// background and ended its turn; when the command exited, the CLI told the model and started a
/// turn of its own. The transcript drew that turn with no opening line, so it read as the footer
/// having been wrong.
///
/// Measured on `claude 2.1.268` on 11 September 2026 with a five second background `sleep`: the
/// first turn's `result`, then `task_updated`, then this line, then a second `init` and the turn
/// the CLI started, whose `result` names `origin: task-notification`. The notification is the one
/// line in that run saying why the turn began, so it is stored and drawn where a prompt would be:
///
///     {"type":"system","subtype":"task_notification","task_id":"b1u04xrxg",
///      "tool_use_id":"toolu_01Bv...","status":"completed","output_file":"/private/tmp/.../b1u04xrxg.output",
///      "summary":"Background command \"Wait five seconds\" completed (exit code 0)"}
///
/// Only a notification arriving between turns is kept. One that lands while a turn is running is
/// read by the model inside that turn and starts nothing, so a row for it would be a turn's opening
/// line drawn in the middle of a turn.
public struct BackgroundWake: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case command
        case agent
    }

    public enum Outcome: Sendable, Equatable {
        case finished
        case failed
        case stopped
    }

    public var source: Source
    public var outcome: Outcome
    /// What the agent called the task when it started it, which for a command is the Bash call's
    /// `description`. Nil when the summary quotes nothing.
    public var name: String?
    public var exitCode: Int?
    /// The CLI's own sentence, whole, for when there is no name to show.
    public var summary: String
    public var outputFile: String?

    /// Read off the CLI's summary, because the notification carries no `task_type` and no
    /// description of its own. Both are on `task_started`, which may have arrived in a process
    /// that has since been replaced by a `--resume`, so the summary is the only account that is
    /// always on the line being drawn. A shape this does not know still draws, as the sentence.
    public init(_ report: SubagentReport) {
        let summary = report.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let exitCode = Self.exitCode(in: summary)
        self.summary = summary
        self.exitCode = exitCode
        self.name = Self.quotedName(in: summary)
        self.source = summary.hasPrefix("Background command") ? .command : .agent
        self.outcome = Self.outcome(status: report.status, exitCode: exitCode)
        self.outputFile = report.outputFile.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What the row says before the chips.
    public var title: String {
        let noun = source == .command ? "Background command" : "Background agent"
        return switch outcome {
        case .finished: "\(noun) finished"
        case .failed: "\(noun) failed"
        case .stopped: "\(noun) stopped"
        }
    }

    /// `exit 0`, or nothing when the summary named no exit code, which is every agent.
    public var exitLabel: String? { exitCode.map { "exit \($0)" } }

    // MARK: Which rows

    private static let probeLength = 256
    private static let marker = Data("\"subtype\":\"task_notification\"".utf8)

    /// Whether a stored row is one of these, by its first bytes. `TranscriptRowInk` and the fold
    /// both ask it once per row per pass, which is why it is a sniff rather than a decode.
    public static func isRow(kind: MessageKind, payload: Data) -> Bool {
        kind == .system && payload.prefix(probeLength).range(of: marker) != nil
    }

    /// Whether a notification arriving now opens a turn, and so is worth a row.
    ///
    /// Between turns it does: the CLI starts one to hand the model the news. A failed or stopped
    /// turn is still between turns, and the CLI wakes after either. While a turn is running, or
    /// holding for an answer, the model reads the notification inside it and nothing new begins.
    public static func opensTurn(during state: SessionState) -> Bool {
        switch state {
        case .idle, .failed, .cancelled: true
        case .running, .waiting: false
        }
    }

    // MARK: Reading the summary

    /// The text between the first and the last double quote. The last rather than the next,
    /// because a description is the agent's own words and may quote something itself.
    private static func quotedName(in summary: String) -> String? {
        guard let open = summary.firstIndex(of: "\""),
              let close = summary.lastIndex(of: "\""),
              open < close else { return nil }
        let name = summary[summary.index(after: open)..<close]
        return name.isEmpty ? nil : String(name)
    }

    private static func exitCode(in summary: String) -> Int? {
        guard let match = summary.firstMatch(of: /\(exit code (-?\d+)\)/) else { return nil }
        return Int(match.1)
    }

    /// A command the CLI calls `completed` can still have failed: the status says the process
    /// ended, and the exit code says how.
    private static func outcome(status: String, exitCode: Int?) -> Outcome {
        switch status {
        case "failed": .failed
        case "killed", "stopped", "cancelled": .stopped
        default: (exitCode ?? 0) == 0 ? .finished : .failed
        }
    }
}
