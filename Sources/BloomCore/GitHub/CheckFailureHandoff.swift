import Foundation

/// Turning a failed CI check into something an agent can act on: which log to ask gh for, how much
/// of it is worth keeping, and the sentence that goes in front of it.
///
/// All of it is here rather than beside the list that draws the checks, because every one of those
/// is a decision with a wrong answer. A run id read out of the wrong half of a URL asks gh for
/// somebody else's job. A log cut at the wrong end throws away the error and keeps the summary
/// nobody needed. A sentence that does not say the check failed leaves the agent guessing what it
/// is looking at. The view's share of this is a button.
public enum CheckFailureHandoff {
    // MARK: - Finding the log

    /// Which GitHub Actions log belongs to a check run, read out of the URL gh already gave us.
    ///
    /// gh reports a check run's `detailsURL` and nothing else that identifies it, so this is the
    /// only handle there is. Two shapes matter: a job URL, `/actions/runs/42/job/99`, which every
    /// Actions check carries, and a bare run URL, `/actions/runs/42`, which is what a rerun link
    /// and some app-generated checks look like. The job is preferred wherever there is one,
    /// because a workflow with eight jobs in it has eight logs and only one of them failed.
    ///
    /// Anything else is nil rather than a guess. A commit status posted by an external service
    /// points at that service's own web page, and there is no log behind it that gh can fetch.
    public struct LogTarget: Sendable, Equatable {
        public var runID: String
        /// The job inside that run, when the URL named one.
        public var jobID: String?

        public init(runID: String, jobID: String? = nil) {
            self.runID = runID
            self.jobID = jobID
        }
    }

    public static func logTarget(detailsURL: String?) -> LogTarget? {
        guard let detailsURL, let url = URL(string: detailsURL),
              let host = url.host?.lowercased(), host == "github.com" || host.hasSuffix(".github.com")
        else { return nil }

        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let runs = parts.firstIndex(of: "runs"), runs > 0, parts[runs - 1] == "actions",
              runs + 1 < parts.count
        else { return nil }

        let runID = parts[runs + 1]
        guard runID.allSatisfy(\.isNumber), !runID.isEmpty else { return nil }

        // `/job/<id>` comes straight after the run, and `/attempts/2/job/<id>` comes after a
        // rerun. Searching for the word rather than counting from the front covers both.
        var jobID: String?
        if let job = parts.firstIndex(of: "job"), job + 1 < parts.count {
            let candidate = parts[job + 1]
            if !candidate.isEmpty, candidate.allSatisfy(\.isNumber) { jobID = candidate }
        }
        return LogTarget(runID: runID, jobID: jobID)
    }

    // MARK: - How much of a log to keep

    /// The head of the log, in lines.
    ///
    /// Kept because the first error is not always near the end. A compiler that reports two
    /// hundred errors prints the first one at the top and then repeats itself, and a test runner
    /// that dies in setup says so before it says anything else. Forty lines is about a screen.
    public static let headLines = 40

    /// The tail of the log, in lines. Much longer than the head, because the tail is where a
    /// failure normally is: the assertion that failed, the summary that counts it, the exit code.
    public static let tailLines = 160

    /// The most text that goes into a log excerpt whatever the line count says, so a single line
    /// holding a megabyte of minified output cannot get through the line budget above.
    public static let maxCharacters = 24_000

    /// What was kept of a log, and what it cost.
    public struct Excerpt: Sendable, Equatable {
        public var text: String
        /// How many lines the original had.
        public var totalLines: Int
        /// How many were dropped out of the middle.
        public var droppedLines: Int

        public var isTruncated: Bool { droppedLines > 0 }

        public init(text: String, totalLines: Int, droppedLines: Int) {
            self.text = text
            self.totalLines = totalLines
            self.droppedLines = droppedLines
        }
    }

    /// A log reduced to the part worth reading, from both ends.
    ///
    /// **Both ends, rather than the tail alone.** The tail is the usual answer and it is not the
    /// only one: a build that failed on its first file prints the error at the top and then
    /// several thousand lines of unrelated work, and a tail-only excerpt of that is a wall of
    /// success ending in "exit 1". Keeping the head as well costs forty lines and covers the case
    /// the tail cannot.
    ///
    /// The middle is replaced by a line saying how much went, so the agent knows it is reading an
    /// excerpt and can go and fetch the rest from the URL in the same prompt if it needs to. A cut
    /// that does not admit it is a cut is how an agent comes to reason about a failure it has only
    /// seen half of.
    public static func excerpt(
        _ log: String,
        headLines: Int = headLines,
        tailLines: Int = tailLines,
        maxCharacters: Int = maxCharacters
    ) -> Excerpt {
        let lines = clean(log)
        let total = lines.count

        guard total > headLines + tailLines else {
            return capped(lines.joined(separator: "\n"), totalLines: total, dropped: 0, limit: maxCharacters)
        }

        let dropped = total - headLines - tailLines
        let kept = lines.prefix(headLines)
            + ["", "[\(dropped) lines of this log are not shown]", ""]
            + lines.suffix(tailLines)
        return capped(
            kept.joined(separator: "\n"), totalLines: total, dropped: dropped, limit: maxCharacters
        )
    }

    /// The character cap, applied after the line budget and from the front, because by this point
    /// what is left is already the two ends of the log and the front of it is the head.
    private static func capped(
        _ text: String, totalLines: Int, dropped: Int, limit: Int
    ) -> Excerpt {
        guard text.count > limit else {
            return Excerpt(text: text, totalLines: totalLines, droppedLines: dropped)
        }
        let cut = String(text.prefix(limit)) + "\n[the rest of this log is not shown]"
        return Excerpt(text: cut, totalLines: totalLines, droppedLines: dropped)
    }

    /// A gh log as lines worth putting in front of an agent.
    ///
    /// Two things come off every line. gh prefixes each one with the job name and the step name,
    /// separated by tabs, which is the same forty characters repeated on every line of a thousand
    /// line log and is already said once in the sentence above it. And after that prefix comes the
    /// runner's own ISO timestamp, which is worth about as much and is the width of a phone
    /// number. Both are stripped only when they are recognisably there, so a log in some other
    /// shape is passed through rather than shortened from the left by guesswork.
    ///
    /// Terminal colour is stripped too. A log full of `ESC[0;31m` costs tokens and reads as
    /// corruption in a text box that has no terminal behind it.
    public static func clean(_ log: String) -> [String] {
        log.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            // gh writes a byte order mark before the first line of a job's log, which would
            // otherwise sit in front of the timestamp and stop it being recognised as one.
            var line = String(raw)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if let lastTab = line.range(of: "\t", options: .backwards),
               line.filter({ $0 == "\t" }).count >= 2 {
                line = String(line[lastTab.upperBound...])
            }
            line = stripTimestamp(line)
            return stripAnsi(line).trimmingCharacters(in: .whitespaces)
        }
    }

    /// `2026-08-22T14:05:11.1234567Z ` off the front, and nothing that is not that.
    private static func stripTimestamp(_ line: String) -> String {
        guard let space = line.firstIndex(of: " ") else { return line }
        let head = line[line.startIndex..<space]
        guard head.count >= 20, head.hasSuffix("Z"), head.contains("T"),
              head.prefix(4).allSatisfy(\.isNumber)
        else { return line }
        return String(line[line.index(after: space)...])
    }

    private static func stripAnsi(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        var out = ""
        var scanning = false
        for character in line {
            if scanning {
                // A CSI sequence ends at its first letter. Nothing else in one is worth keeping.
                if character.isLetter { scanning = false }
                continue
            }
            if character == "\u{1B}" { scanning = true; continue }
            out.append(character)
        }
        return out
    }

    // MARK: - What the agent is told

    /// What the log file is called once it is an attachment.
    ///
    /// Named after the check rather than after the run, because the check's name is what the user
    /// clicked and what the sentence beside the chip says. `.log` so the agent reads it as text and
    /// the review pane does not try to draw it as a picture.
    public static func logFilename(for name: String, at date: Date = .now, timeZone: TimeZone = .current) -> String {
        // A check's name is whatever the workflow author typed, and on GitHub that includes
        // slashes (`build / test (macos)`), colons and the occasional backtick. A slash would
        // silently put the file in another folder, a colon is rewritten by the Finder, and a
        // backtick would close the code span the path is written inside in the draft.
        var safe = name
        for bad in ["/", ":", "`"] { safe = safe.replacingOccurrences(of: bad, with: "-") }
        safe = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        while safe.hasPrefix(".") { safe.removeFirst() }
        let label = safe.isEmpty ? "check" : safe
        return "\(label) \(PastedAttachment.timestamp(date, in: timeZone)).log"
    }

    /// The sentence written into the draft, which is the whole of what the agent is told besides
    /// the log itself.
    ///
    /// It says four things and no more: which check, that it failed and in what words, where the
    /// log is, and where the whole of it lives if the excerpt is not enough. Anything else would be
    /// Bloom putting an instruction in the user's mouth. The draft is left for the user to finish,
    /// because "fix this" and "why did this happen" are different requests and only they know
    /// which one they are making.
    public static func sentence(
        name: String,
        workflow: String? = nil,
        state: CheckState,
        detailsURL: String? = nil,
        logPath: String? = nil,
        excerpt: Excerpt? = nil
    ) -> String {
        let place = workflow.map { $0.isEmpty || $0 == name ? "" : " in \($0)" } ?? ""
        var sentence = "The GitHub check \"\(name)\"\(place) \(state.description.lowercased())."

        if let logPath {
            let cut = excerpt?.isTruncated == true
                ? " Only part of the log is there, taken from both ends of it."
                : ""
            sentence += " Its log is in \(AttachmentDraft.token(for: logPath)).\(cut)"
        } else {
            sentence += " Bloom could not fetch its log."
        }

        if let detailsURL, !detailsURL.isEmpty { sentence += " The run is at \(detailsURL)." }
        return sentence
    }
}
