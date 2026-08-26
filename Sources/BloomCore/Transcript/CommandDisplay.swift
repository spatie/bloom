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
/// the part below; and a `cd` anywhere else is left exactly as the agent wrote it, because a
/// command that ran outside this workspace is the thing a reader most needs to notice.
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
        /// A directory below the worktree, named by `location`.
        case subdirectory(String)
        /// Outside the worktree, or somewhere this cannot name. Nothing is dropped.
        case elsewhere
        /// No `cd` to read. Nothing is dropped.
        case unstated
    }

    public var place: Place
    /// What the row draws: the command with the consumed `cd` chain removed, or the whole of the
    /// original where nothing may be removed.
    public var command: String

    /// The path below the worktree, and empty for every other place. The view draws this ahead of
    /// `command`, in its own ink.
    public var location: String {
        guard case .subdirectory(let path) = place else { return "" }
        return path
    }

    public init(place: Place, command: String) {
        self.place = place
        self.command = command
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
                return CommandDisplay(place: .elsewhere, command: command)
            case .moved(let destination, let remainder):
                directory = destination
                rest = remainder
                moved = true
            }
        }

        guard moved else { return untouched }
        guard let below = relation(of: directory, to: root) else {
            return CommandDisplay(place: .elsewhere, command: command)
        }
        // A row is never left blank, so a bare `cd somewhere` keeps its own text.
        guard !rest.isEmpty else { return untouched }

        return CommandDisplay(place: below.isEmpty ? .workspace : .subdirectory(below), command: String(rest))
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
        // A word Bloom would have to run a shell to understand, and `cd -`, which is a
        // destination only the shell's own history knows.
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
