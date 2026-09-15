import Foundation

/// One thing wrong with a settings file, said in a sentence the owner can act on.
///
/// A settings file inside the repository is committed, so it reaches this machine by `git pull`
/// and is written by whoever last touched it. A mistake in it is therefore nobody here's fault and
/// cannot be allowed to cost anything: the loader skips the one entry that is wrong, keeps every
/// other, and records one of these so the window can say what went missing and where to look.
///
/// `message` is shown as it is, so it is short and plain and names the entry the way the file
/// does. `line` is there when the parser could say where the entry starts, which is a table header
/// or a `key = value` line, and nil for anything written inline.
public struct SettingsIssue: Sendable, Hashable {
    /// Which part of the file the sentence is about.
    public enum Entry: Sendable, Hashable {
        /// The whole file, which was skipped because it would not parse.
        case file
        /// A run script, by its table name under `scripts.run`.
        case runScript(String)
        /// A `[[quick_prompts]]` entry, by its position from zero, and by name when it had a
        /// usable one.
        case quickPrompt(index: Int, name: String?)
    }

    /// The settings file, as `SettingsLoader` names it: absolute.
    public var path: String
    public var message: String
    public var entry: Entry
    public var line: Int?

    public init(path: String, message: String, entry: Entry, line: Int? = nil) {
        self.path = path
        self.message = message
        self.entry = entry
        self.line = line
    }
}
