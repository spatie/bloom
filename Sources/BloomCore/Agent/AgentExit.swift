import Foundation

/// Why the agent's process ended without finishing the turn.
///
/// Read off the stored payload first and the text second. `subtype` already separates a process
/// that died from a row Bloom could not write, and inside a process exit the shape of a runtime
/// crash dump is a format rather than a guess: the indented `at` frames are the marker, and the
/// error line is the last non-empty line above the first of them. Nothing here is decided by
/// looking for particular words in the output.
public enum AgentExitCause: Sendable, Hashable {
    /// The CLI's own runtime threw and took the process down with it. The string is the one line
    /// the runtime printed above its stack.
    case crashed(String)
    /// There was nothing on PATH to run.
    case missing
    /// The CLI printed something for a person to read before it stopped.
    case reported(String)
    /// It printed nothing at all.
    case silent
    /// Bloom could not write the row. The agent is not what failed.
    case storage(String)
}

/// What an `.error` row says, in words a person can act on.
///
/// The row used to print whatever the CLI had last written to stderr. A CLI that dies inside its
/// own bundle writes a Node crash dump there, and the second line of that dump is the source line
/// the fault landed on: for a bundled CLI that is the whole bundle on one line, twenty five
/// thousand characters of minified JavaScript. The transcript drew that as the error message, so
/// the one row whose job was to say what went wrong said nothing readable, and the turn ended with
/// a red row and no next step.
///
/// The full text is not thrown away. It stays in `detail`, behind the row's disclosure, the same
/// place a tool's output lives.
public struct AgentExit: Sendable, Hashable {
    /// The exit status, when the process got far enough to have one.
    public let status: Int?
    public let cause: AgentExitCause
    /// Everything the CLI wrote, kept whole.
    public let detail: String
    /// The resolved path of what Bloom launched, when the payload carried one.
    ///
    /// Worth a sentence of its own, because the name of an agent's command is not the same thing
    /// as the file behind it. A machine can hold several `claude` binaries, and the one a Finder
    /// launched app resolves need not be the one the same user's terminal resolves.
    public let command: String

    public init(status: Int?, cause: AgentExitCause, detail: String, command: String = "") {
        self.status = status
        self.cause = cause
        self.detail = detail
        self.command = command
    }

    // MARK: What the row says

    /// The label in the row's first column.
    public var title: String {
        if case .storage = cause { return "Not saved" }
        return status.map { "Agent exited (\($0))" } ?? "Agent error"
    }

    /// The sentence beside the label. One line, always, whatever arrived on stderr.
    public var summary: String {
        switch cause {
        case .crashed(let error):
            Self.oneLine(Self.stopped("The CLI crashed: \(error)"))
        case .missing:
            "Bloom could not find the agent's command."
        case .reported(let text):
            Self.oneLine(text)
        case .silent:
            "It stopped without printing anything."
        case .storage(let message):
            Self.oneLine(message)
        }
    }

    /// What to do next, and whether the work is safe. Every exit has one: a red row that leaves a
    /// person guessing whether their worktree survived is the thing this type exists to prevent.
    public var advice: String {
        switch cause {
        case .crashed:
            """
            This is a fault in the CLI itself rather than in your work. Nothing in this \
            conversation was lost, and everything the agent had already changed is still in the \
            worktree. Run the CLI once in a terminal to see whether it starts at all, update it if \
            it does not, then send the turn again.
            """ + ranCommand
        case .missing:
            """
            Install the agent's CLI, or put it somewhere Bloom looks, then send the turn again. \
            Nothing in this conversation was lost.
            """
        case .reported:
            """
            Nothing in this conversation was lost, and everything the agent had already changed is \
            still in the worktree. Open this row for everything the CLI printed, then send the \
            turn again.
            """ + ranCommand
        case .silent:
            """
            Nothing in this conversation was lost, and everything the agent had already changed is \
            still in the worktree. Send the turn again, and if it stops here a second time, run \
            the CLI once in a terminal to see what it says.
            """ + ranCommand
        case .storage:
            """
            The agent itself kept running. It is Bloom's copy of the conversation that is missing \
            a row, so check that the disk is not full, then reopen the workspace.
            """
        }
    }

    /// Which file was launched, said out loud, wherever the answer could be the binary.
    ///
    /// Nothing to add for a command that was never found, which has no path to name, or for a
    /// write of Bloom's own that failed, which is not about the agent's binary at all.
    private var ranCommand: String {
        command.isEmpty ? "" : " Bloom ran \(command)."
    }

    /// Whether the disclosure has anything to show that the summary does not already say.
    public var hasDetail: Bool {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != summary
    }

    // MARK: Reading a payload

    /// The stored `.error` payload, as `AgentRunner` writes it.
    public static func decode(_ payload: Data) -> AgentExit {
        guard let json = JSONValue.parse(payload) else {
            return AgentExit(status: nil, cause: .silent, detail: "")
        }
        return read(json)
    }

    public static func read(_ json: JSONValue?) -> AgentExit {
        let status = json?["status"]?.intValue
        let stderr = json?["stderr"]?.stringValue ?? ""
        let command = json?["command"]?.stringValue ?? ""

        // The subtype is the payload's own answer to "whose failure was this", and it is written
        // by the same code that writes the row. A storage failure carries a message and never a
        // stderr, so reading it as a process exit would draw an empty row.
        if json?["subtype"]?.stringValue == "storage" {
            let message = json?["message"]?.stringValue ?? ""
            let cause: AgentExitCause = message.isEmpty ? .silent : .storage(message)
            return AgentExit(status: status, cause: cause, detail: message)
        }

        return AgentExit(
            status: status,
            cause: cause(status: status, stderr: stderr),
            detail: stderr,
            command: command
        )
    }

    /// Classify what a dead process left behind.
    public static func cause(status: Int?, stderr: String) -> AgentExitCause {
        let text = stripEscapes(stderr)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .silent }

        // 127 with Bloom's own sentence beside it. `StreamingProcess` writes that line when it
        // cannot resolve the executable, so this is Bloom reading its own words rather than
        // guessing at somebody else's.
        if status == 127, text.contains(Self.notFoundMarker) { return .missing }

        if let error = errorLine(inStack: text) { return .crashed(error) }

        return .reported(readable(text))
    }

    // MARK: Shapes

    /// The sentence `StreamingProcess` writes when nothing on PATH matches.
    static let notFoundMarker = "not found on PATH"

    /// How long a line may be before it is taken for machine output rather than a message. A
    /// minified bundle arrives as a single line of tens of thousands of characters, and the whole
    /// point of this file is that such a line never reaches a row.
    static let lineLimit = 400

    /// How much of a message a row will hold before it is cut.
    static let summaryLimit = 200

    /// A whole stderr that fits in a row is shown as it is, rather than reduced to its first
    /// line. A real error of three short lines must not lose two of them to a rule written for a
    /// crash dump.
    static var verbatimLimit: Int { summaryLimit }

    /// The line a runtime prints above its stack.
    ///
    /// The frames are the marker, because "one or more lines starting with `at `" is what every
    /// JavaScript stack looks like and it is not something a sentence does. Node prints the file
    /// and line, the source line the fault landed on, a caret, a blank line, then the error, then
    /// the frames, so the error is the last non-empty line above the first frame. Returning nil
    /// leaves the text to be read as an ordinary message.
    static func errorLine(inStack text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let firstFrame = lines.firstIndex(where: isStackFrame) else { return nil }

        for index in stride(from: firstFrame - 1, through: 0, by: -1) {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // The source line of a bundled CLI is the bundle. Refusing it here is what keeps the
            // row a sentence for the crash this was written for.
            guard line.count <= lineLimit else { return nil }
            // A thrown error is named before it is described: `TypeError: message`. Without that
            // shape this is some other indented output and not a stack at all.
            guard let separator = line.range(of: ": "),
                  line.distance(from: line.startIndex, to: separator.lowerBound) <= 80,
                  separator.lowerBound != line.startIndex,
                  separator.upperBound != line.endIndex
            else { return nil }
            return cut(line)
        }
        return nil
    }

    static func isStackFrame(_ line: String) -> Bool {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        guard indent.count >= 2 else { return false }
        let rest = line.dropFirst(indent.count)
        return rest.hasPrefix("at ") && rest.count > 3
    }

    /// The part of some ordinary diagnostic output worth putting in a row.
    ///
    /// A short one is kept whole, folded onto one line. A long one is reduced to its first line
    /// that carries something, skipping blanks and skipping any line long enough to be machine
    /// output rather than a message.
    static func readable(_ text: String) -> String {
        let folded = oneLine(text, limit: verbatimLimit)
        if folded.count <= verbatimLimit { return folded }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.count > lineLimit { continue }
            return cut(trimmed)
        }
        // Every line was too long to read. The row still says something true rather than showing
        // the first two hundred characters of a bundle.
        return "The CLI printed \(text.count) characters of output and no message."
    }

    // MARK: Text

    /// Terminal colour codes, which a CLI writes to stderr whenever it thinks it has a terminal.
    /// Left in `detail`, taken out of anything drawn as prose.
    static func stripEscapes(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }

        var out = ""
        out.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "\u{1B}" else {
                out.append(character)
                continue
            }
            // CSI and OSC both run until a byte in a known range. Anything else after the escape
            // is a two character sequence, so dropping the escape alone is enough.
            guard let next = iterator.next() else { break }
            if next == "[" {
                while let inner = iterator.next() {
                    if inner.isLetter { break }
                }
            } else if next == "]" {
                while let inner = iterator.next() {
                    if inner == "\u{07}" { break }
                    if inner == "\u{1B}" { pending = inner; break }
                }
            }
        }
        return out
    }

    /// Collapses every run of whitespace so a message occupies exactly one row.
    static func oneLine(_ text: String, limit: Int = summaryLimit) -> String {
        var out = ""
        out.reserveCapacity(min(text.count, limit + 1))
        var pendingSpace = false

        for character in text {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
            // Only once a character past the limit exists, so a message of exactly the length a
            // row holds is not marked as cut when nothing was cut from it.
            if out.count > limit {
                out.removeLast()
                return out + "\u{2026}"
            }
        }
        return out
    }

    /// A sentence Bloom writes itself ends in a stop. The CLI's own text never gets one added:
    /// that text is quoted rather than written, and a fragment is what the CLI chose to print.
    static func stopped(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }

    static func cut(_ text: String) -> String {
        guard text.count > summaryLimit else { return text }
        return String(text.prefix(summaryLimit)) + "\u{2026}"
    }
}
