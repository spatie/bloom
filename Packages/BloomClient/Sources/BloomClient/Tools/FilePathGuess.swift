import Foundation

/// Whether a piece of a tool call is a file, decided from the text alone.
///
/// The transcript draws a file the way the composer draws an attached one: the icon its type
/// deserves, then its name. That only works if the thing being drawn really is a file. A tool call
/// carries all sorts of arguments and most of them are not: `app/Beacon/**/*.php` is a glob,
/// `pest --filter=Beacon` is a command, `\bfoo\b` is a pattern, `https://example.com/a.php` is a
/// page. A shell command wearing a file icon is a much worse mistake than a filename set in the
/// monospace chip it has always used, so everything here leans the same way: when the answer is
/// not obvious, it is no.
///
/// **This is only asked about arguments whose meaning is not fixed.** Where the tool's own contract
/// says a field is a file, which is `Read`, `Write`, `Edit`, `MultiEdit` and `NotebookEdit`, the
/// presenter believes it and asks nothing here beyond `isWellFormed`. That split is what lets the
/// rule below be as strict as it is: a screenshot called `CleanShot 2026-08-19 at 09.29.05@2x.png`
/// is drawn as a file because `Read` said it was one, not because a guess got lucky on a name with
/// four spaces in it.
///
/// **Nothing here touches the disk.** A transcript is hundreds of rows in a lazy list and a stat
/// per row is a stat per row scrolled past, on the main actor, for an answer that would be the
/// wrong one anyway: a file the agent wrote at step three and deleted at step nine was a file the
/// whole time, and the row that names it is a record of what happened rather than a picker. So a
/// path that has since been deleted, renamed, or that lives in another checkout entirely still
/// reads as a file. Whether it can be *opened* is a separate question, answered by `relative`.
public enum FilePathGuess {
    /// Longer than any path worth drawing. `PATH_MAX` is 1024 on macOS, but a chip that is going
    /// to be truncated to a name anyway gains nothing from accepting a kilobyte, and the cap is
    /// what stops a pathological argument from being walked character by character.
    public static let maxLength = 260

    /// Characters that end the guess wherever they appear.
    ///
    /// Two families, both of which say "this is not a name":
    ///
    /// - Shell and regex punctuation: `* ? [ ] { }` are globs, `| & ; < > $ \` ( ) ' " ` are how a
    ///   command is written, `= , : #` separate a flag from its value or a path from a line number.
    /// - Whitespace of any kind, which is the one deliberate false negative. `npm run dev` and
    ///   `pest --filter=Beacon` both contain a space and so does `My Notes.md`. Rejecting the space
    ///   costs a real file the monospace chip it has today; accepting it would put a document icon
    ///   on a command line. Only the ambiguous fields pay that cost, because a field the tool
    ///   declares to be a file never reaches this test.
    ///
    /// `@`, `+`, `-`, `_`, `~` inside a component and accented letters are all left alone: they
    /// turn up in real names (`icon@2x.png`, `layout_v2.blade.php`) and none of them makes a string
    /// read as code.
    private static let rejected = Set<Character>("*?[]{}|&;<>$\\`()'\"=,:#%!^\n\r\t ")

    /// The loose test: could this be drawn as a path at all.
    ///
    /// Asked about the fields a tool has already promised are files, where the only real risks are
    /// an empty string, something enormous, or a value that is not a path because the CLI changed
    /// shape underneath us.
    public static func isWellFormed(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= maxLength else { return false }
        return !path.contains(where: \.isNewline)
    }

    /// The strict test: does this read as the name of a file.
    ///
    /// Accepts `HarbourMap.php`, `Sources/Bloom/Views/Palette.swift`, `/Users/x/notes.md`.
    /// Rejects, deliberately:
    ///
    /// - globs and patterns, on the punctuation above
    /// - commands, on the punctuation and on whitespace
    /// - URLs, on `:` and on the scheme
    /// - directories, because a directory has no extension to recognise, and `Sources/Bloom` and
    ///   `Sources/Bloom.swift` are told apart by nothing else
    /// - dotfiles with no extension of their own: `.gitignore`, `.env`. They are files, and they
    ///   are indistinguishable from a name that begins with a full stop, so they keep the
    ///   monospace chip
    /// - anything with no extension at all: `Makefile`, `LICENSE`, a bare word from a search
    /// - a version or a figure: `1.2.3`, `Section 3.5`. An extension has to contain a letter
    public static func looksLikeAFile(_ text: String) -> Bool {
        guard isWellFormed(text) else { return false }
        // Before the character scan, because `://` is the clearest single signal in the set and a
        // URL is the argument most likely to otherwise end in a plausible looking extension.
        guard !text.contains("://") else { return false }
        guard !text.contains(where: { rejected.contains($0) }) else { return false }
        // A flag, not a path.
        guard !text.hasPrefix("-") else { return false }
        // A home relative path is a path, but not one the worktree can resolve, and `~` is also
        // how a range and a fuzzy match are written.
        guard !text.hasPrefix("~") else { return false }
        // Trailing slash is how a directory is written when someone means it.
        guard !text.hasSuffix("/") else { return false }

        let components = text.split(separator: "/", omittingEmptySubsequences: false)
        for (index, component) in components.enumerated() {
            // A leading slash is an absolute path and its first component is empty by
            // construction. An empty one anywhere else is `//`, which no tool writes on purpose.
            if component.isEmpty {
                guard index == 0, components.count > 1 else { return false }
                continue
            }
            // `..` is a path, but it is a path out of the worktree and it is also how a range is
            // written in half the arguments in a transcript.
            guard component != ".." else { return false }
        }

        guard let name = components.last else { return false }
        return hasExtension(name)
    }

    /// `name.ext`, where the stem is not empty and the extension is one to eight letters or digits
    /// with at least one letter among them.
    private static func hasExtension(_ name: Substring) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }

        let stem = name[name.startIndex..<dot]
        guard !stem.isEmpty else { return false }

        let ext = name[name.index(after: dot)...]
        guard (1...8).contains(ext.count) else { return false }
        guard ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        return ext.contains(where: \.isLetter)
    }

    /// Where the worktree would find this file, or nil if it is somewhere else entirely.
    ///
    /// Bloom opens a file by handing the review a path relative to the worktree, and an agent
    /// writes absolute ones: Claude Code requires an absolute `file_path` on every read. So the
    /// two have to be reconciled before a chip can be clicked, and a chip naming a file in another
    /// checkout, in the user's home directory or in a temporary folder honestly has nowhere to
    /// open: it stays a chip, it just does not answer to the pointer.
    ///
    /// A relative path is taken at face value. Every agent Bloom runs is spawned with the worktree
    /// as its working directory, so a relative argument is already relative to exactly the place
    /// the review resolves against.
    public static func relative(_ path: String, to worktree: String) -> String? {
        guard isWellFormed(path), !worktree.isEmpty else { return nil }

        guard !path.hasPrefix("~") else { return nil }

        guard path.hasPrefix("/") else {
            let trimmed = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            // Out of the worktree by the front door. Nothing can be resolved from here without
            // knowing where the worktree itself sits, which is the answer this returns.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("../") else { return nil }
            return trimmed
        }

        let root = worktree.hasSuffix("/") ? String(worktree.dropLast()) : worktree
        guard path.hasPrefix(root + "/") else { return nil }

        let inside = String(path.dropFirst(root.count + 1))
        return inside.isEmpty ? nil : inside
    }
}
