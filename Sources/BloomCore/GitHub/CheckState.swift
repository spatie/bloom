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

    /// The mark this state is drawn with, as an SF Symbol name.
    ///
    /// A symbol name is usually the drawing's business and `TurnEnding` says so in as many words.
    /// This one is not, because the property worth holding is not which circle each state gets: it
    /// is that the six states have six DIFFERENT shapes, so the column can be read by someone who
    /// cannot tell the amber one from the green one, and by anyone at all on a selected row, where
    /// `CheckRunRow` drops the tint and the shape is the whole of what is left. That is a claim
    /// about all six at once, which is exactly the kind of claim a view cannot make and a suite
    /// can. `CheckStateTests` makes it.
    ///
    /// Running was `circle.dashed`, and it was reported from a screenshot: in a list of thirteen
    /// rows where eleven had passed and two were still going, the two running ones read as absent
    /// rather than as busy. A dashed outline is mostly gaps, and the gaps are the whole of it:
    /// measured off the offscreen render at the size the column draws, the ring covered 26 percent
    /// of the ink a `checkmark.circle.fill` beside it covers. No colour makes up a difference that
    /// size. `record.circle.fill` covers 91 percent of it, so a run in flight now weighs what a run
    /// that finished weighs and differs from it by shape and by hue rather than by being fainter.
    /// It is also what GitHub draws for the same event, which is where the comparison came from.
    ///
    /// Queued keeps the clock. It is the state where nothing is executing, and a mark with a
    /// runner's weight would say something is.
    public var symbolName: String {
        switch self {
        case .queued: "clock"
        case .running: "record.circle.fill"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "minus.circle"
        case .neutral: "circle"
        }
    }

    /// Whether the mark is a solid disc rather than an outline.
    ///
    /// The three states a healthy branch actually shows are passed, failed and running, and they
    /// have to weigh the same or the lightest of them reads as nothing at all. That is the bug
    /// above, stated as a property the suite can hold rather than as a note in a comment.
    public var isFilledMark: Bool {
        symbolName.hasSuffix(".fill")
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
