import Foundation

/// What a failed setup script actually said, and what to do about it.
///
/// The row used to show the last line of the log. That is wrong more often than it is right, and
/// the run that prompted this is the ordinary case rather than a corner one: `psql` prints its
/// error and then an indented question underneath it, so the row said
/// "Is the server running on that host and accepting TCP/IP connections?" and never showed the
/// line that said what had happened. Tools print a hint, a usage note or a blank line after a
/// failure all the time.
///
/// ## How the failing line is found
///
/// Two rules, in order, and neither of them is a list of words that mean trouble.
///
/// 1. **The last line in the POSIX diagnostic format**, which is `program: error: text`, or a line
///    that opens with `error:` or `fatal:`. That format is what compilers, `git`, `psql` and most
///    of the tools a setup script calls print their failures in, and it is a shape rather than a
///    vocabulary. Only the last twenty lines with anything on them are looked at, so a warning
///    five hundred lines up in a build log cannot be mistaken for the thing that stopped the run.
/// 2. **Otherwise, the last line that begins a line of its own.** A line that starts with
///    whitespace is a continuation of the one above it, which is exactly what the `psql` question
///    is, and a continuation is never the failure. This is what fixes the reported bug even for a
///    tool that does not use the diagnostic format at all.
///
/// ## How much is diagnosed
///
/// Deliberately very little. A wrong diagnosis is worse than none, and most setup scripts fail in
/// ways nobody has a rule for, so the fallback has to stay good: the real error line, said plainly,
/// with the whole log one press away. Two failures are recognised, and both are recognised by the
/// string the C library itself printed rather than by anything Bloom guessed:
///
/// - `Connection refused`, which is `ECONNREFUSED` and always means the same thing: nothing was
///   listening. The host and port come out of the same line when the tool named them.
/// - `command not found`, which the shell prints in one of two fixed shapes.
///
/// Everything else gets a summary and no advice, which is still a great deal better than a
/// fragment of a sentence.
public struct SetupDiagnosis: Sendable, Hashable {
    /// The line that says what failed, as the script printed it, with its surrounding space taken
    /// off. Empty only when the log is empty.
    public let summary: String

    /// The line of the script the shell put the failure on, when it said. `bash` and `zsh` both
    /// print `<file>: line <n>: <message>`, and that number is worth more than any prose.
    public let scriptLine: Int?

    /// What to do about it, when the failure is one of the two that are recognised. Empty
    /// otherwise, and an empty one is not a gap.
    public let advice: String

    /// What the script exited with, when Bloom watched the run. Nil for a workspace reopened long
    /// afterwards, where the log survives and the run does not.
    public let status: Int?

    public init(summary: String, scriptLine: Int? = nil, advice: String = "", status: Int? = nil) {
        self.summary = summary
        self.scriptLine = scriptLine
        self.advice = advice
        self.status = status
    }

    // MARK: What the row says

    /// The label in the row's first column. The status is in it for the same reason `AgentExit`
    /// puts one in its own: a number a person can look up beats a sentence somebody invented.
    public var title: String {
        status.map { "Setup failed (\($0))" } ?? "Setup failed"
    }

    /// The sentence under the row: the remedy, and where the shell says it happened.
    public var sentence: String {
        [advice, scriptLine.map { "The shell put it at line \($0) of the script." } ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Reading a log

    public static func read(log: String, status: Int? = nil) -> SetupDiagnosis {
        let summary = failureLine(in: log)
        return SetupDiagnosis(
            summary: summary,
            scriptLine: scriptLine(in: summary),
            advice: advice(for: summary),
            status: status
        )
    }

    /// How far back a diagnostic line is looked for, counted in lines with something on them.
    ///
    /// A bound rather than a preference. Without one, a `warning: ... error: ...` line early in a
    /// long `composer install` would outrank the line the run actually stopped on.
    private static let reach = 20

    /// A log broken into the lines a reader sees.
    ///
    /// Normalised before it is split, because in Swift a `\r\n` is ONE `Character` rather than
    /// two: splitting on `"\n"` does not see it at all, and a script whose output has Windows
    /// line endings arrives here as a single enormous line. Both spellings become `\n` first,
    /// which is the same normalisation `MarkdownParser` opens with and for the same reason.
    static func split(_ log: String) -> [String] {
        log.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    static func failureLine(in log: String) -> String {
        let lines = split(log)

        var end = lines.count
        while end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        guard end > 0 else { return "" }

        var seen = 0
        var index = end - 1
        while index >= 0, seen < reach {
            let line = lines[index]
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                seen += 1
                if isDiagnostic(line) { return line.trimmingCharacters(in: .whitespaces) }
            }
            index -= 1
        }

        index = end - 1
        while index >= 0 {
            let line = lines[index]
            if !line.trimmingCharacters(in: .whitespaces).isEmpty, !isContinuation(line) {
                return line.trimmingCharacters(in: .whitespaces)
            }
            index -= 1
        }

        return lines[end - 1].trimmingCharacters(in: .whitespaces)
    }

    /// Whether this line carries on the one above it rather than starting something.
    static func isContinuation(_ line: String) -> Bool {
        guard let first = line.first, first == " " || first == "\t" else { return false }
        return !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether this line is written in the diagnostic format.
    static func isDiagnostic(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces).lowercased()
        for opening in ["error:", "fatal:", "fatal error:"] where value.hasPrefix(opening) {
            return true
        }
        for marker in [": error:", ": fatal:", ": fatal error:"] where value.contains(marker) {
            return true
        }
        return false
    }

    // MARK: The two failures that are recognised

    static func advice(for summary: String) -> String {
        let value = summary.lowercased()
        if value.contains("connection refused") { return refusedAdvice(summary) }
        if value.contains("command not found") { return notFoundAdvice(summary) }
        return ""
    }

    /// Ports a reader is entitled to be reminded about. Named as "usually", because that is all
    /// this is: a fact about the port, not a claim about what was meant to be running.
    private static let wellKnown: [Int: String] = [
        5432: "Postgres",
        3306: "MySQL",
        6379: "Redis",
        27_017: "MongoDB",
        9_200: "Elasticsearch",
    ]

    private static func refusedAdvice(_ summary: String) -> String {
        let port = number(after: "port ", in: summary)
        let host = host(in: summary)

        let place: String
        switch (host, port) {
        case let (host?, port?): place = "on \(host):\(port)"
        case let (nil, port?): place = "on port \(port)"
        case let (host?, nil): place = "on \(host)"
        default: place = "where the script tried to connect"
        }

        let named = port.flatMap { wellKnown[$0] }.map { ", which is where \($0) usually is" } ?? ""
        return "Nothing was listening \(place)\(named). Start it and run setup again."
    }

    private static func notFoundAdvice(_ summary: String) -> String {
        // Two fixed shapes, and they put the name on opposite sides of the phrase. zsh writes
        // `zsh: command not found: psql`; bash writes `run.sh: line 12: psql: command not found`.
        // zsh is tested for first, because bash's shape is a suffix of a line that zsh's is not:
        // reading bash's rule over a zsh line answers "zsh", which is the shell rather than the
        // command it could not find.
        var name = ""
        if let marker = summary.range(of: "command not found: ") {
            name = summary[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        } else if let marker = summary.range(of: ": command not found") {
            name = summary[..<marker.lowerBound]
                .split(separator: ":").last
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }

        guard !name.isEmpty else {
            return "Something the script called is not on the PATH it ran with."
        }
        return "\(name) is not on the PATH the setup script ran with."
    }

    // MARK: Reading a line apart

    static func scriptLine(in summary: String) -> Int? {
        guard let marker = summary.range(of: ": line ") else { return nil }
        let rest = summary[marker.upperBound...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, rest.dropFirst(digits.count).first == ":" else { return nil }
        return Int(digits)
    }

    private static func number(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// The host in a connection failure, in the two shapes tools write it.
    ///
    /// `psql` says `at "127.0.0.1", port 5432`; `curl` says `to localhost port 3000`. Nothing is
    /// invented when neither is there.
    private static func host(in text: String) -> String? {
        if let opening = text.range(of: "at \""),
           let closing = text[opening.upperBound...].firstIndex(of: "\"") {
            let value = String(text[opening.upperBound..<closing])
            return value.isEmpty ? nil : value
        }
        if let marker = text.range(of: " port ") {
            let word = text[..<marker.lowerBound].split(separator: " ").last.map(String.init)
            return word?.isEmpty == false ? word : nil
        }
        return nil
    }
}

/// One line of a setup log, and whether it is part of what failed.
///
/// The whole log used to be painted as error text the moment a run failed, so a script that
/// created a symlink, restarted nginx and issued a certificate before it stopped looked like a
/// total loss and gave no clue where it actually stopped. Only the failure reads as failure.
///
/// A continuation of the failing line counts as part of it, which is what keeps `psql`'s indented
/// question with the error it belongs to instead of stranding it in the ordinary ink.
public struct SetupLogLine: Sendable, Hashable, Identifiable {
    public let id: Int
    public let text: String
    public let isFailure: Bool

    public init(id: Int, text: String, isFailure: Bool) {
        self.id = id
        self.text = text
        self.isFailure = isFailure
    }

    public static func lines(of text: String, failing summary: String) -> [SetupLogLine] {
        var result: [SetupLogLine] = []
        var carrying = false

        for (index, value) in SetupDiagnosis.split(text).enumerated() {
            let trimmed = value.trimmingCharacters(in: .whitespaces)

            if !summary.isEmpty, trimmed == summary {
                carrying = true
            } else if carrying, !SetupDiagnosis.isContinuation(value) {
                carrying = false
            }

            result.append(SetupLogLine(id: index, text: value, isFailure: carrying))
        }
        return result
    }
}
