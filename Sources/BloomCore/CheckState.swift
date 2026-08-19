import BloomCore

/// What a single GitHub check run amounts to, once gh's two overlapping fields have been reconciled.
enum CheckState {
    case running
    case passed
    case failed
    case skipped
    case neutral

    /// gh reports two shapes through one field, and an in-flight run has no conclusion at all,
    /// so status is only trusted once a conclusion exists to contradict it.
    init(_ run: CheckRun) {
        guard let conclusion = run.conclusion?.uppercased() else {
            self = run.status.uppercased() == "COMPLETED" ? .neutral : .running
            return
        }
        self = switch conclusion {
        case "SUCCESS": .passed
        case "SKIPPED": .skipped
        case "NEUTRAL": .neutral
        case "PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING": .running
        case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED",
             "STARTUP_FAILURE", "STALE": .failed
        default: .neutral
        }
    }

    /// Colour alone cannot carry this: the glyphs differ in shape too, and VoiceOver gets the word.
    var description: String {
        switch self {
        case .running: "Running"
        case .passed: "Passed"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .neutral: "No result"
        }
    }
}
