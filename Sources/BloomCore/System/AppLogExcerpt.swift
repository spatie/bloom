import Foundation

/// The last few minutes of what Bloom told its own log, made fit to send with a feedback report.
///
/// Bloom logs almost nothing, and what it does log is the one thing a bug report can never
/// reconstruct: the moment the app decided not to do what it was just asked to do. See `Log` in
/// the app target for why that log exists at all. This is the part of offering it to somebody
/// else that is a judgement rather than a read: how far back "recent" goes, how much of it there
/// may be, and what has to come out of every line before it is allowed to leave the machine.
///
/// **The excerpt is what is sent, character for character.** The Feedback sheet's View link shows
/// exactly this string, produced by exactly this code, and not a sample of it or a description of
/// it. That is the whole reason the checkbox can be offered at all: somebody can read the thing
/// before they decide.
///
/// **What comes out.** A Bloom log line can name a workspace, a project, a branch, a path, and
/// through an error's own text anything the system chose to put in it. None of that is anybody's
/// business but the user's, so every line goes through `scrubbed` twice over: once against the
/// shapes that are recognisable on sight (a credential, a URL, an email address, an absolute
/// path), and once against the words this particular Mac is known to use for its own work, which
/// the app hands over as a `Redaction`. What is left says what happened without saying whose work
/// it happened to.
///
/// **What can never be in it.** The log is Bloom's own writing, so nothing here ever opens a file:
/// `~/.claude.json` and `~/.codex/auth.json` are not read, not tailed and not named. A token could
/// only reach a log line by way of an error message that carried one, which is what the credential
/// shapes are for, and the catch-all rule that takes out any unbroken run of forty characters is
/// what covers the shapes nobody has thought of yet.
public enum AppLogExcerpt {
    /// One line as the log store hands it over, reduced to the three things a reader needs.
    public struct Entry: Sendable, Equatable {
        public var date: Date
        /// One of `Log`'s categories: `archive`, `composer`, `updates`, `ping`, `icons`,
        /// `permissions`.
        public var category: String
        public var message: String

        public init(date: Date, category: String, message: String) {
            self.date = date
            self.category = category
            self.message = message
        }
    }

    // MARK: - What "recent" means

    /// How far back the excerpt reaches.
    ///
    /// Half an hour, and it is a deliberate choice rather than a round number. Somebody writing a
    /// feedback report is writing about something that just happened to them, so the useful lines
    /// are the ones from the last few minutes; everything older is somebody else's session inside
    /// the same launch of the app, and sending it would mean sending work they have stopped
    /// thinking about. Half an hour is long enough to still hold the thing that went wrong while
    /// they went to make coffee and came back annoyed about it.
    public static let window: TimeInterval = 30 * 60

    /// The most lines that may be sent, counted from the newest backwards.
    public static let maxEntries = 200

    /// The most characters that may be sent. A hard stop after the two caps above, because one
    /// pathological line is enough to make a cap on the number of lines meaningless.
    public static let maxCharacters = 20_000

    /// The most any single line may contribute. An error's `localizedDescription` can be a
    /// paragraph; the first sentence of it is the part that says what broke.
    public static let maxEntryCharacters = 400

    /// What is written where something was left out, so the reader is never shown a tidy excerpt
    /// that is quietly missing its middle.
    public static let elision = "…"

    /// What the View link shows when there is nothing to show, which is the ordinary case: Bloom
    /// logs only refusals, so a session where nothing was refused logs nothing at all.
    public static let empty = "Bloom has not written anything to its log since it started."

    // MARK: - Words this Mac uses for its own work

    /// One thing to take out of every line, and what to put in its place.
    public struct Word: Sendable, Equatable {
        public var text: String
        public var placeholder: String

        public init(text: String, placeholder: String) {
            self.text = text
            self.placeholder = placeholder
        }
    }

    /// The names this Mac would recognise and nobody else should see.
    ///
    /// Handed in rather than discovered, because BloomCore cannot know what the user called their
    /// projects and the app can: it has the list on screen. A name is not a shape and cannot be
    /// matched by a pattern, so the only honest way to keep "Rewrite the billing importer" out of
    /// an excerpt is to be told that it is a workspace name.
    public struct Redaction: Sendable, Equatable {
        public var words: [Word]

        public init(words: [Word] = []) {
            self.words = Redaction.ordered(words)
        }

        /// Below this a name is not worth replacing and is dangerous to replace: a project called
        /// `api` would turn every mention of an API in an error message into a placeholder, and
        /// the excerpt would stop being readable without anything being protected.
        public static let minimumLength = 4

        public static func of(
            projects: [String] = [],
            workspaces: [String] = [],
            branches: [String] = [],
            user: String? = nil,
            host: String? = nil
        ) -> Redaction {
            var words: [Word] = []
            words += projects.map { Word(text: $0, placeholder: Placeholder.project) }
            words += workspaces.map { Word(text: $0, placeholder: Placeholder.workspace) }
            words += branches.map { Word(text: $0, placeholder: Placeholder.branch) }
            if let user { words.append(Word(text: user, placeholder: Placeholder.user)) }
            if let host { words.append(Word(text: host, placeholder: Placeholder.host)) }
            return Redaction(words: words)
        }

        /// Longest first, so a branch named `fix-the-importer` is taken out before the workspace
        /// named `fix` can leave half of it behind. Trimmed, deduplicated, and anything too short
        /// dropped.
        static func ordered(_ words: [Word]) -> [Word] {
            var seen: Set<String> = []
            return
                words
                .map { Word(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), placeholder: $0.placeholder) }
                .filter { $0.text.count >= minimumLength }
                .filter { seen.insert($0.text.lowercased()).inserted }
                .sorted { $0.text.count > $1.text.count }
        }
    }

    /// What replaces something that was taken out. Readable on purpose: an excerpt full of
    /// `<workspace>` says plainly that Bloom removed a name, where a blanked run of x's reads as
    /// corruption.
    public enum Placeholder {
        public static let secret = "<redacted>"
        public static let url = "<url>"
        public static let email = "<email>"
        public static let path = "<path>"
        public static let project = "<project>"
        public static let workspace = "<workspace>"
        public static let branch = "<branch>"
        public static let user = "<user>"
        public static let host = "<host>"
    }

    // MARK: - The excerpt

    /// The whole excerpt, capped and scrubbed: what the checkbox sends and what the View link
    /// shows.
    public static func excerpt(
        _ entries: [Entry],
        since: Date? = nil,
        redaction: Redaction = Redaction(),
        timeZone: TimeZone = .current
    ) -> String {
        let kept = entries
            .filter { entry in since.map { entry.date >= $0 } ?? true }
            .suffix(maxEntries)

        let lines = kept.map { line($0, redaction: redaction, timeZone: timeZone) }
        guard !lines.isEmpty else { return empty }

        return capped(lines.joined(separator: "\n"))
    }

    /// One line: the time it happened, what part of the app said it, and what it said.
    ///
    /// No date, because every line in the excerpt is from the same half hour, and no log level,
    /// because Bloom's log has one purpose and every line in it is worth the same. Newlines are
    /// folded into spaces so that one line of the excerpt is one thing that happened, which is
    /// what makes the caps below mean anything.
    public static func line(
        _ entry: Entry,
        redaction: Redaction = Redaction(),
        timeZone: TimeZone = .current
    ) -> String {
        let message = truncated(
            folded(scrubbed(entry.message, redaction: redaction)),
            to: maxEntryCharacters
        )
        let category = truncated(folded(entry.category), to: 32)
        return "\(time(entry.date, in: timeZone))  \(category)  \(message)"
    }

    // MARK: - Taking things out

    /// One line with everything that is not Bloom's business taken out of it.
    ///
    /// The order is the point. The credential shapes go first, because a token inside a URL has to
    /// be caught as a token before the URL around it is replaced by something tidy. Then the
    /// shapes that are personal whatever they contain: a URL, an email address, an absolute path.
    /// Then the catch-all, which by then is only looking at what is left, so a long path is
    /// reported as a path rather than as an unexplained redaction. Then the words this Mac uses
    /// for its own work, last, because by then there is much less text for them to match inside.
    public static func scrubbed(_ text: String, redaction: Redaction = Redaction()) -> String {
        var result = text

        for rule in credentialPatterns + shapePatterns + [catchAll] {
            result = result.replacingOccurrences(
                of: rule.pattern, with: rule.template, options: [.regularExpression]
            )
        }

        for word in redaction.words {
            result = result.replacingOccurrences(
                of: word.text, with: word.placeholder, options: [.caseInsensitive]
            )
        }

        return result
    }

    /// Anything shaped like a credential, whether or not anybody knows how it got into a log line.
    static let credentialPatterns: [(pattern: String, template: String)] = [
        // A PEM header, and the body after it goes with the catch-all below.
        (#"-----BEGIN[^-]{0,64}-----"#, Placeholder.secret),
        // A JWT, which is what `~/.codex/auth.json` holds.
        (#"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{4,}"#, Placeholder.secret),
        (#"(?i)\b(?:sk|pk|rk)-[A-Za-z0-9_-]{12,}"#, Placeholder.secret),
        (#"\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{16,}"#, Placeholder.secret),
        (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, Placeholder.secret),
        (#"\bAKIA[0-9A-Z]{16}\b"#, Placeholder.secret),
        (#"\bAIza[0-9A-Za-z_-]{16,}"#, Placeholder.secret),
        // Anything introduced as a secret keeps its introduction and loses its value, so the line
        // still says what kind of thing was being talked about.
        (
            #"(?i)\b(authorization|bearer|token|secret|password|passwd|api[_-]?key|apikey|access[_-]?key|private[_-]?key)\b["']?\s*[:=]?\s*\S+"#,
            "$1 " + Placeholder.secret
        ),
    ]

    /// The rule that matters most, and it is deliberately blunt: an unbroken run of forty
    /// characters that could be base64 is not a word anybody typed, and no sentence Bloom writes
    /// to its log has one in it. This is what covers the token format nobody here has heard of.
    ///
    /// Last of the patterns, after paths and URLs have already been named for what they are, so
    /// that a long path is reported as a path rather than as an unexplained redaction.
    static let catchAll: (pattern: String, template: String) =
        (#"[A-Za-z0-9+/_-]{40,}={0,2}"#, Placeholder.secret)

    /// The shapes that are personal whatever they happen to contain.
    static let shapePatterns: [(pattern: String, template: String)] = [
        (#"[a-zA-Z][a-zA-Z0-9+.-]{1,20}://[^\s'"]+"#, Placeholder.url),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,24}"#, Placeholder.email),
        // A home-relative path, and an absolute one of at least two components. One component is
        // not enough: `/tmp` and `/usr` name nothing about anybody, and taking them out would only
        // make the line harder to read.
        (#"~(?:/[A-Za-z0-9._+-]+)+"#, Placeholder.path),
        (#"(?<![A-Za-z0-9._~-])(?:/[A-Za-z0-9._+-]+){2,}"#, Placeholder.path),
    ]

    // MARK: - Caps

    /// The excerpt cut to `maxCharacters`, from the front, on a line boundary.
    ///
    /// From the front because a log is only interesting at the end, which is the same reason
    /// `LogTail` exists and takes what it takes from there. The first line says so, rather than
    /// the excerpt simply starting mid-thought.
    static func capped(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }

        let tail = String(text.suffix(maxCharacters))
        guard let firstBreak = tail.firstIndex(of: "\n") else {
            return "\(elision)\n\(tail)"
        }
        return "\(elision)\n\(tail[tail.index(after: firstBreak)...])"
    }

    static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + elision
    }

    /// Newlines and runs of whitespace folded into single spaces.
    static func folded(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespaces)
    }

    /// `14:22:07`, in a fixed locale, because this is a log rather than something being read
    /// aloud.
    static func time(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
