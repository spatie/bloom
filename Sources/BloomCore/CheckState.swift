/// What a single GitHub check run amounts to, once gh's two overlapping fields have been reconciled.
///
/// Here rather than beside the row that draws it, because it is not a view's business: it is the
/// same "what did gh actually say" reconciliation `GitHub.rollup` does, and the app's test suite
/// only builds this module. Sitting in the view layer it was the one piece of gh parsing nothing
/// could assert on, which is how it came to read an empty conclusion as a real one.
public enum CheckState: Sendable, Hashable {
    /// GitHub has the job and nobody has picked it up yet. Nothing is executing, so nothing moves.
    case queued
    /// A runner is executing it right now.
    case running
    case passed
    case failed
    case skipped
    case neutral

    /// gh reports two shapes through one field, and an in-flight run has no conclusion at all,
    /// so status is only trusted once a conclusion exists to contradict it.
    ///
    /// "No conclusion" is two different pieces of JSON, which is what this got wrong. gh marshals
    /// its Go structs without `omitempty`, so a run that has not finished carries `"conclusion":
    /// ""` rather than `"conclusion": null`. Read as a present value, the empty string matched
    /// nothing below and every check still in flight fell through to `.neutral`, which is why a
    /// running check drew the same blank circle as a check that finished with no result.
    public init(_ run: CheckRun) {
        guard let conclusion = run.conclusion?.uppercased(), !conclusion.isEmpty else {
            self = Self.fromStatus(run.status)
            return
        }
        self = switch conclusion {
        case "SUCCESS": .passed
        case "SKIPPED": .skipped
        case "NEUTRAL": .neutral
        // A commit status reports its state through this field rather than through `status`, so
        // the in-flight words arrive here too.
        case "IN_PROGRESS", "PENDING": .running
        case "QUEUED", "WAITING", "EXPECTED", "REQUESTED": .queued
        // Cancelled, timed out and action required are not failures in GitHub's vocabulary, but
        // they are here, because `GitHub.rollup` counts exactly this list when it decides the
        // strip above the list is red. A row that disagreed with its own header would be worse
        // than a row that is blunt: "1 required check failed" over six neutral circles.
        case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED",
             "STARTUP_FAILURE", "STALE": .failed
        default: .neutral
        }
    }

    /// What a run with no conclusion yet is doing. `COMPLETED` without a conclusion is the one
    /// case where the status is exhausted and there is genuinely nothing to report.
    private static func fromStatus(_ status: String) -> CheckState {
        switch status.uppercased() {
        case "COMPLETED": .neutral
        case "IN_PROGRESS", "PENDING": .running
        default: .queued
        }
    }

    /// Colour alone cannot carry this: the glyphs differ in shape too, and VoiceOver gets the word.
    public var description: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .passed: "Passed"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .neutral: "No result"
        }
    }
}
