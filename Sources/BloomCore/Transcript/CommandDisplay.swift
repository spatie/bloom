import Foundation

/// Which of a shell command's leading `cd` a transcript row may hide, and what has to survive it.
///
/// Every Bash row in a workspace opened with the same sixty odd characters of worktree path, in a
/// column that holds about eighty, so the part that differed was off the right edge on every row.
/// The workspace is named in the sidebar and in the title bar; the row does not have to say it a
/// third time.
///
/// What may be hidden is a decision about what a person is shown, so it is here rather than in the
/// view. The rule: a `cd` to the worktree itself is dropped, because a row with no `cd` at all
/// already means "ran in the worktree" and both are the same fact; a `cd` below the worktree keeps
/// the part below; and a `cd` anywhere else is left whole and marked, because a command that ran
/// outside this workspace is the thing a reader most needs to notice.
///
/// **Ask this before `ToolPresenter.oneLine`, not after.** A newline is one of the separators a
/// `cd` can end with, and the collapse turns it into a space, which is indistinguishable from a
/// `cd` with two arguments.
///
/// Nothing here touches the disk: no symlinks resolved, no `~` expanded, no variable substituted.
/// A destination it cannot resolve is `elsewhere`, which shows more rather than less.
public struct CommandDisplay: Equatable, Sendable {
    /// Where the command ran, as far as its own text says.
    public enum Place: Equatable, Sendable {
        /// The workspace's own worktree. The prefix is dropped.
        case workspace
        /// A directory below the worktree, named by the path below it.
        case subdirectory(String)
        /// Outside the worktree, or somewhere this cannot name. Nothing is dropped. The prefix is
        /// the `cd` that left, and is empty where the text could not be split into one.
        case elsewhere(prefix: String)
        /// No `cd` to read. Nothing is dropped.
        case unstated
    }

    /// What a row draws ahead of the command, in its own ink.
    public enum Lead: Equatable, Sendable {
        case none
        /// A directory below the worktree. The command ran there rather than at the root.
        case location(String)
        /// The `cd` that left the worktree, kept whole. Its ink is what makes the row stand out.
        case prefix(String)

        public var text: String {
            switch self {
            case .none: ""
            case .location(let path): path
            case .prefix(let text): text
            }
        }

        /// Between the lead and the command. A location is a tag on the row and gets a mark of its
        /// own; a prefix is part of the command and keeps the space it had.
        public var joiner: String {
            switch self {
            case .none: ""
            case .location: " \u{203A} "
            case .prefix: " "
            }
        }

        public var tint: ToolTint {
            switch self {
            case .none: .neutral
            case .location: .accent
            case .prefix: .warning
            }
        }
    }

    public var place: Place
    /// What the row draws: the command with the consumed `cd` chain removed, or the whole of the
    /// original where nothing may be removed.
    public var command: String

    public init(place: Place, command: String) {
        self.place = place
        self.command = command
    }

    /// Derived from `place` rather than stored beside it, so the two cannot disagree.
    public var lead: Lead {
        switch place {
        case .workspace, .unstated: .none
        case .subdirectory(let path): .location(path)
        case .elsewhere(let prefix): prefix.isEmpty ? .none : .prefix(prefix)
        }
    }

    /// True where the command left the workspace, however that was spelled.
    public var leftTheWorkspace: Bool {
        if case .elsewhere = place { return true }
        return false
    }

    /// The whole detail as one string, lead and all: what a row measures and what it reads as.
    public var line: String {
        let lead = lead
        return lead.text.isEmpty ? command : lead.text + lead.joiner + command
    }

    public static func of(_ command: String, worktree: String) -> CommandDisplay {
        let untouched = CommandDisplay(place: .unstated, command: command)
        // A worktree that is not an absolute path is not one this can compare against.
        guard worktree.hasPrefix("/") else { return untouched }
        let root = normalise(worktree)
        guard root != "/" else { return untouched }

        var rest = Substring(command)
        var directory = root
        var moved = false

        loop: while true {
            switch step(rest, from: directory) {
            case .notMoved:
                break loop
            case .opaque:
                // Nothing is hidden and nothing is marked: there is no prefix this could honestly
                // point at.
                return CommandDisplay(place: .elsewhere(prefix: ""), command: command)
            case .moved(let destination, let remainder):
                directory = destination
                rest = remainder
                moved = true
            }
        }

        guard moved else { return untouched }
        // A row is never left blank, so a bare `cd somewhere` keeps its own text.
        guard !rest.isEmpty else { return untouched }

        guard let below = relation(of: directory, to: root) else {
            let consumed = command[..<rest.startIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandDisplay(place: .elsewhere(prefix: consumed), command: String(rest))
        }
        return CommandDisplay(
            place: below.isEmpty ? .workspace : .subdirectory(below),
            command: String(rest)
        )
    }

    // MARK: Reading one `cd`

    private enum Step {
        /// Not a `cd`, so the walk stops here.
        case notMoved
        /// A `cd` whose destination cannot be worked out from the text: `~`, `$TMPDIR`, a
        /// substitution, an unbalanced quote.
        case opaque
        case moved(String, Substring)
    }

    private static func step(_ text: Substring, from directory: String) -> Step {
        var scan = text.drop(while: \.isWhitespace)
        guard scan.hasPrefix("cd") else { return .notMoved }
        scan = scan.dropFirst(2)
        guard let next = scan.first, next == " " || next == "\t" else { return .notMoved }
        scan = scan.drop(while: { $0 == " " || $0 == "\t" })

        guard let word = word(&scan) else { return .opaque }
        // A word Bloom would have to run a shell to understand, and `cd -`, whose destination only
        // the shell's own history knows.
        let readable = !word.contains("$") && !word.contains("`") && !word.hasPrefix("~") && word != "-"
        guard readable else { return .opaque }

        var after = scan.drop(while: { $0 == " " || $0 == "\t" })
        if after.hasPrefix("&&") {
            after = after.dropFirst(2)
        } else if after.hasPrefix(";") {
            after = after.dropFirst()
        } else if let first = after.first, !first.isNewline {
            // `cd a b`, `cd a || b`, `cd a & b`: the `cd` is not simply a prefix, so leave it all.
            return .notMoved
        }

        return .moved(resolve(word, against: directory), after.drop(while: \.isWhitespace))
    }

    /// One shell word, unquoted. Nil for an unbalanced quote, which is a command this should not
    /// be guessing at.
    private static func word(_ scan: inout Substring) -> String? {
        var out = ""
        var quote: Character?

        while let character = scan.first {
            if let open = quote {
                scan = scan.dropFirst()
                if character == open { quote = nil } else { out.append(character) }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                scan = scan.dropFirst()
                continue
            }
            if character == "\\" {
                scan = scan.dropFirst()
                guard let escaped = scan.first else { return nil }
                out.append(escaped)
                scan = scan.dropFirst()
                continue
            }
            if character.isWhitespace || character == ";" || character == "&" || character == "|" { break }
            out.append(character)
            scan = scan.dropFirst()
        }

        guard quote == nil, !out.isEmpty else { return nil }
        return out
    }

    // MARK: Paths

    /// Relative resolves against the worktree, because that is the directory every agent Bloom
    /// runs is spawned in.
    private static func resolve(_ path: String, against directory: String) -> String {
        path.hasPrefix("/") ? normalise(path) : normalise(directory + "/" + path)
    }

    /// Absolute, no trailing slash, `.` and `..` applied. Textual only.
    private static func normalise(_ path: String) -> String {
        var components: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = components.popLast(); continue }
            components.append(part)
        }
        return "/" + components.joined(separator: "/")
    }

    /// The part of `path` below `root`, empty where they are the same, and nil for anything
    /// outside. `/a/bc` is not inside `/a/b`, which is what the separator is for.
    private static func relation(of path: String, to root: String) -> String? {
        if path == root { return "" }
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }
}
